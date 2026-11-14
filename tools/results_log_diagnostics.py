#!/usr/bin/env python3
"""Bounded Results/Loki diagnostics; also shipped to the Locust workers."""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import time


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def sanitize_text(value):
    """Redact common credential forms without recording request headers ourselves.

    This is an additional precaution, not a replacement for CI artifact censoring.
    """
    value = str(value)
    value = re.sub(r"(?i)\bBearer\s+[A-Za-z0-9._~+/-]+=*", "Bearer [REDACTED]", value)
    value = re.sub(
        r'''(?ix)(["']?(?:authorization|proxy-authorization|token|access_token|refresh_token|'''
        r'''id_token|password|passwd|secret|secret_access_key|aws_secret_access_key|'''
        r'''access_key|access_key_id|aws_access_key_id|client_secret|x-amz-security-token|'''
        r'''x-amz-signature|x-amz-credential)["']?\s*[:=]\s*)'''
        r'''(\[[^\]\n]*\]|"[^"\n]*"|'[^'\n]*'|[^\s,;&}]+)''',
        lambda m: m[1] + (m[2][0] + '[REDACTED]' + m[2][0]
                          if m[2][0] in ('"', "'") else '[REDACTED]'), value)
    value = re.sub(r"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b", "[REDACTED]", value)
    value = re.sub(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b", "[REDACTED]", value)
    return re.sub(r"(https?://)[^\s/@:]+:[^\s/@]+@", r"\1[REDACTED]@", value)


def api_records(text, namespace, pod, container):
    """Decode whole JSON objects, including messages containing nested braces."""
    records = []
    malformed = 0
    for line in text.splitlines():
        start = line.find('{')
        if start < 0:
            continue
        try:
            entry, _ = json.JSONDecoder().raw_decode(line[start:])
        except ValueError:
            malformed += 1
            continue
        if not isinstance(entry, dict):
            continue
        record = dict(namespace=namespace, pod=pod, container=container,
                      timestamp=entry.get('ts', entry.get('time')))
        for key in ('level', 'caller', 'grpc.start_time', 'grpc.request.deadline',
                    'grpc.method', 'grpc.code', 'grpc.time_duration_in_ms'):
            record[key] = entry.get(key)
        for key in ('msg', 'message', 'error'):
            if key in entry:
                record['message' if key == 'msg' else key] = sanitize_text(entry[key])
        records.append(record)
    return records, malformed


def collect(output, since_time=None, budget=60, include_locust=False):
    output = Path(output)
    logs_dir = output / 'results-loki-pod-logs'
    logs_dir.mkdir(parents=True, exist_ok=True)
    deadline = time.monotonic() + budget
    report = dict(started_at=utc_now(), since_time=since_time, pods=[], streams=[], errors=[])
    records = []

    def call(namespace, args):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError('Diagnostic collection budget exhausted')
        result = subprocess.run(
            ['kubectl', '--request-timeout=10s', '-n', namespace] + args,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
            encoding='utf-8', errors='replace',
            timeout=min(10, remaining))
        if result.returncode:
            raise RuntimeError(sanitize_text(result.stderr)[:512])
        return result.stdout

    def error(namespace, operation, exc):
        report['errors'].append(dict(namespace=namespace, operation=operation,
                                     error=sanitize_text(exc)[:512]))

    targets = [('openshift-pipelines', 'api'), ('tekton-pipelines', 'api'),
               ('openshift-logging', 'loki')]
    if include_locust:
        targets.insert(0, ('locust-operator', 'locust'))
    # Preserve the historical combined API log and summary paths for consumers.
    with (output / 'results-api-logs.txt').open('w') as combined:
        for namespace, kind in targets:
            args = ['get', 'pods', '-o', 'json']
            if kind == 'api':
                args += ['-l', 'app.kubernetes.io/name=tekton-results-api']
            elif kind == 'locust':
                args += ['-l', 'locust.io/test-run=fetch-log-test']
            try:
                pods = json.loads(call(namespace, args)).get('items', [])
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
                error(namespace, 'list pods', exc)
                continue
            for pod in pods:
                name = pod['metadata']['name']
                if kind == 'loki' and not name.startswith('logging-loki-'):
                    continue
                statuses = {c['name']: c for c in pod.get('status', {}).get('containerStatuses', [])}
                containers = pod.get('spec', {}).get('containers', [])
                report['pods'].append(dict(
                    namespace=namespace, pod=name, node=pod.get('spec', {}).get('nodeName'),
                    created_at=pod['metadata'].get('creationTimestamp'),
                    containers=[dict(name=c['name'], image=c.get('image'), resources=c.get('resources'),
                                     restart_count=statuses.get(c['name'], {}).get('restartCount', 0),
                                     last_termination_reason=statuses.get(c['name'], {}).get(
                                         'lastState', {}).get('terminated', {}).get('reason'))
                                for c in containers]))
                for container in containers:
                    cname = container['name']
                    restarted = statuses.get(cname, {}).get('restartCount', 0) > 0
                    for previous in ([False, True] if restarted else [False]):
                        suffix = '-previous' if previous else ''
                        path = logs_dir / '{}-{}-{}{}.log'.format(namespace, name, cname, suffix)
                        args = ['logs', name, '-c', cname, '--timestamps=true', '--tail=10000']
                        if since_time:
                            args += ['--since-time=' + since_time]
                        if previous:
                            args += ['--previous=true']
                        try:
                            raw = call(namespace, args)
                            path.write_text(sanitize_text(raw))
                            stream = dict(namespace=namespace, pod=name, container=cname,
                                          previous=previous, file=str(path.relative_to(output)), tail_limit=10000)
                            if kind == 'api':
                                parsed, malformed = api_records(raw, namespace, name, cname)
                                for record in parsed:
                                    record['previous'] = previous
                                records.extend(parsed)
                                stream['malformed_json_lines'] = malformed
                                combined.write(sanitize_text(raw) + '\n')
                            report['streams'].append(stream)
                        except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
                            error(namespace, 'logs {}/{}{}'.format(name, cname, suffix), exc)
    try:
        stack = json.loads(call('openshift-logging', ['get', 'lokistack', 'logging-loki', '-o', 'json']))
        report['loki_stack'] = {k: stack.get('spec', {}).get(k)
                                for k in ('size', 'replicationFactor', 'limits', 'storageClassName')}
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        error('openshift-logging', 'LokiStack settings', exc)
    (output / 'results-api-logs.json').write_text(json.dumps(records, indent=2) + '\n')
    report['ended_at'] = utc_now()
    (output / 'results-log-diagnostics.json').write_text(json.dumps(report, indent=2) + '\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    parser.add_argument('--since-time')
    parser.add_argument('--budget', type=int, default=60)
    parser.add_argument('--include-locust', action='store_true')
    args = parser.parse_args()
    if args.budget <= 0:
        parser.error('--budget must be positive')
    result = collect(args.output, args.since_time, args.budget, args.include_locust)
    print('Captured {} log streams; {} diagnostic collection errors'.format(
        len(result['streams']), len(result['errors'])))
    raise SystemExit(int(bool(result['errors'])))
