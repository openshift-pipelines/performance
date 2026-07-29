"""PostgreSQL data fetcher for Horreum performance data.

SAFETY: This module enforces READ-ONLY access. The target is a production
Horreum database — no writes are permitted under any circumstances.
"""

import logging

logger = logging.getLogger(__name__)


def make_readonly_connection(conn):
    """Force a psycopg2 connection into read-only mode.

    Sets the session to READ ONLY at the PostgreSQL protocol level,
    preventing any INSERT/UPDATE/DELETE/CREATE even if a bug introduces one.
    """
    conn.set_session(readonly=True, autocommit=False)
    logger.info("Database connection set to READ ONLY mode")


def _build_test_id_predicate(variant_config):
    """Build SQL predicate matching the Grafana testIdPredicate logic.

    Queries both the new per-variant test ID and the legacy test ID
    (with HA/QBT config filtering) combined with OR.
    """
    new_id = variant_config["new_test_id"]
    legacy_id = variant_config.get("legacy_test_id")
    legacy_filter = variant_config.get("legacy_filter")

    predicate = f"horreum_testid = {new_id}"

    if legacy_id and legacy_filter:
        legacy_conditions = []

        ha = legacy_filter.get("ha_enabled", False)
        qbt = legacy_filter.get("qbt_enabled", False)

        if ha:
            legacy_conditions.append(
                "(label_values->>'__deployment_haConfig_haEnabled')::BOOLEAN = true"
            )
            ct = legacy_filter.get("controller_type")
            if ct:
                legacy_conditions.append(
                    f"(label_values->>'__deployment_haConfig_controllerType') = '{ct}'"
                )
        else:
            legacy_conditions.append(
                "(NOT (label_values ? '__deployment_haConfig_haEnabled') "
                "OR (label_values->>'__deployment_haConfig_haEnabled')::BOOLEAN = false)"
            )

        if qbt:
            legacy_conditions.append(
                "(label_values ? '__deployment_qbtConfig_qbtEnabled') "
                "AND (label_values->>'__deployment_qbtConfig_qbtEnabled')::BOOLEAN = true"
            )
        else:
            legacy_conditions.append(
                "(NOT (label_values ? '__deployment_qbtConfig_qbtEnabled') "
                "OR (label_values->>'__deployment_qbtConfig_qbtEnabled')::BOOLEAN = false)"
            )

        legacy_clause = " AND ".join(legacy_conditions)
        predicate = f"({predicate} OR (horreum_testid = {legacy_id} AND {legacy_clause}))"

    return predicate


def _build_metric_extractions(metric_keys):
    """Build SQL expressions to extract metric values from JSONB."""
    extractions = []
    for key in metric_keys:
        col = key.replace(".", "_")
        extractions.append(
            f"(label_values->>'__{key}')::DOUBLE PRECISION AS \"{col}\""
        )
    return ",\n    ".join(extractions)


def fetch_runs(conn, component_config, variant_name, variant_config,
               version, limit, metric_keys):
    """Fetch the last N runs for a specific component/variant/version.

    Returns list of dicts, one per run, with metric values and metadata.
    """
    test_id_pred = _build_test_id_predicate(variant_config)
    group_by = component_config.get("group_by")
    extractions = _build_metric_extractions(metric_keys)

    group_select = ""
    if group_by:
        group_select = f"(label_values->>'__{group_by}') AS group_key,"

    if group_by:
        partition_col = f"(label_values->>'__{group_by}')"
        query = f"""
            SELECT * FROM (
                SELECT
                    start,
                    (label_values->>'__metadata_env_BUILD_ID') AS build_id,
                    (label_values->>'__deployment_version') AS version,
                    {partition_col} AS group_key,
                    {extractions},
                    ROW_NUMBER() OVER (
                        PARTITION BY {partition_col}
                        ORDER BY start DESC
                    ) AS rn
                FROM data
                WHERE {test_id_pred}
                  AND (
                    CASE
                      WHEN label_values ? '__deployment_nightly'
                           AND (label_values->>'__deployment_nightly')::BOOLEAN = true
                      THEN 'nightly'
                      ELSE COALESCE(label_values->>'__deployment_version', 'unknown')
                    END
                  ) = %s
            ) sub
            WHERE rn <= %s
            ORDER BY group_key, start DESC
        """
    else:
        query = f"""
            SELECT
                start,
                (label_values->>'__metadata_env_BUILD_ID') AS build_id,
                (label_values->>'__deployment_version') AS version,
                {extractions}
            FROM data
            WHERE {test_id_pred}
              AND (
                CASE
                  WHEN label_values ? '__deployment_nightly'
                       AND (label_values->>'__deployment_nightly')::BOOLEAN = true
                  THEN 'nightly'
                  ELSE COALESCE(label_values->>'__deployment_version', 'unknown')
                END
              ) = %s
            ORDER BY start DESC
            LIMIT %s
        """

    cursor = conn.cursor()
    cursor.execute(query, (version, limit))
    columns = [desc[0] for desc in cursor.description]
    rows = cursor.fetchall()
    cursor.close()

    runs_by_group = {}
    for row in rows:
        run = dict(zip(columns, row))
        run["_start"] = str(run.pop("start", ""))
        run["_build_id"] = run.pop("build_id", "")
        run.pop("rn", None)

        gk = str(run.pop("group_key", "_all")) if group_by else "_all"

        for key in metric_keys:
            col = key.replace(".", "_")
            if col in run:
                run[key] = run.pop(col)

        runs_by_group.setdefault(gk, []).append(run)

    return runs_by_group


def fetch_all_data(conn, config, version_a, version_b, limit):
    """Fetch data for all components/variants for both versions.

    If version_b is None, only version_a data is fetched (benchmark mode).

    Returns nested dict: {component: {variant: {group_key, version_a: {gk: [runs]}, version_b: {gk: [runs]}}}}
    """
    all_data = {}

    for comp_name, comp_config in config["components"].items():
        all_data[comp_name] = {}
        metric_keys = [m["key"] for m in comp_config["metrics"]]

        for var_name, var_config in comp_config["variants"].items():
            logger.info("Fetching %s / %s ...", comp_name, var_name)

            runs_a = fetch_runs(
                conn, comp_config, var_name, var_config,
                version_a, limit, metric_keys,
            )

            runs_b = {}
            if version_b is not None:
                runs_b = fetch_runs(
                    conn, comp_config, var_name, var_config,
                    version_b, limit, metric_keys,
                )

            all_data[comp_name][var_name] = {
                "group_key": comp_config.get("group_by"),
                "version_a": runs_a,
                "version_b": runs_b,
            }

    return all_data
