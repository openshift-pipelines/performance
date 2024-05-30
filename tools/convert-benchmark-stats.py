#!/usr/bin/env python3
# -*- coding: UTF-8 -*-

'''
# Usage

./convert-benchmark-stats.py <source> <target>

<source>: Path to original benchmark-stats.csv containing namespace field
<target>: Path to target location to save the new benchmark-stats.csv 
'''

import sys
import pandas as pd

column_names = [
    'monitoring_start',
    'monitoring_now',
    'monitoring_second',
    'prs_total',
    'prs_pending',
    'prs_running',
    'prs_finished',
    'prs_signed_true',
    'prs_signed_false',
    'prs_finalizers_present',
    'prs_finalizers_absent',
    'prs_started_worked',
    'prs_started_failed',
    'prs_deleted',
    'prs_terminated',
    'trs_total',
    'trs_pending',
    'trs_running',
    'trs_finished',
    'trs_signed_true',
    'trs_signed_false',
    'trs_finalizers_present',
    'trs_finalizers_absent',
    'trs_deleted',
    'trs_terminated',
]

def main(benchmark_stats_file, out):
    df = pd.read_csv(benchmark_stats_file)
    namespace_count = len(df.namespace.unique())
    n = df.shape[0]
    df_series = []

    for i in range(0, n, namespace_count):
        # Take groups based on namespace count
        sub_df = df.iloc[i:i+namespace_count]
        last_row_idx = sub_df.shape[0] - 1
        monitoring_start = sub_df.iloc[0]['monitoring_start']
        monitoring_now = sub_df.iloc[last_row_idx]['monitoring_now']
        monitoring_second = sub_df.iloc[last_row_idx]['monitoring_second']

        # Remove time related fields and sum the sub-group
        sub_df_sum = sub_df.drop(columns=[
            'namespace', 
            'monitoring_start', 
            'monitoring_now', 
            'monitoring_second'
        ]).sum(axis=0)

        # Capture monitoring time stats based on first and last records from the sub-group
        sub_df_sum['monitoring_start'] = monitoring_start
        sub_df_sum['monitoring_now'] = monitoring_now
        sub_df_sum['monitoring_second'] = monitoring_second
        df_series.append(sub_df_sum)

    # Save new result CSV file
    new_df = pd.concat(df_series, axis=1).transpose()
    new_df = new_df[column_names]

    new_df.to_csv(out, index=False)

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Please provide path to benchmark-stats.csv and output file")
        sys.exit(1)
    main(sys.argv[1], sys.argv[2])
