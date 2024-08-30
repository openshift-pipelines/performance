#!/usr/bin/env python3
# -*- coding: UTF-8 -*-

'''
# Usage

./convert-benchmark-stats.py <source> <target>

<source>: Path to original benchmark-stats.csv containing namespace field
<target>: Path to target location to save the new benchmark-stats.csv 
'''

import sys
import math

column_names = [
    'monitoring_start',
    'monitoring_now',
    'monitoring_second',
    'prs_total',
    'prs_failed',
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
    "prs_log_present",
    "prs_result_present",
    "prs_record_present",
    'trs_total',
    'trs_failed',
    'trs_pending',
    'trs_running',
    'trs_finished',
    'trs_signed_true',
    'trs_signed_false',
    'trs_finalizers_present',
    'trs_finalizers_absent',
    'trs_deleted',
    'trs_terminated',
    "trs_log_present",
    "trs_result_present",
    "trs_record_present",
]


class CSV_Object:
    def __init__(self, path):
        self.load_from_file(path)

    def load_from_file(self, path):
        with open(path, 'r', encoding='utf-8') as f:
            data = f.readlines()

            # Fetch Headers
            self.headers = [x.strip() for x in data[0].split(',')]
            self.header_col2idx = { 
                self.headers[i]: i
                for i in range(len(self.headers))
            }

            # Fetch data columns
            data_rows = []

            for data in data[1:]:
                data_rows.append(
                    [x.strip() for x in data.split(',')]
                )

            self.data_rows = data_rows
            self.row_count = len(data_rows)
            self.col_count = len(self.headers)

    def __getitem__(self, col_name):
        result = []
        for row in self.data_rows:
            col_val = row[self.header_col2idx[col_name]]
            result.append(col_val)
        return result

    def unique(self, col_name):
        seen = set()
        result = []
        for row in self.data_rows:
            col_val = row[self.header_col2idx[col_name]]
            if col_val not in seen:
                seen.add(col_val)
                result.append(col_val)
        return result


def main(benchmark_stats_file, out):
    csv_data = CSV_Object(benchmark_stats_file)

    namespace_count = len(csv_data.unique('namespace'))
    n = csv_data.row_count
    result_rows = []

    batches = math.ceil(n // namespace_count)

    for batch in range(batches):
        # Group by namespaces

        # For last batch, take last nth records based on namespace count as
        # start index (as we could have less number of records)
        if batch == batches - 1:
            start_idx = n - namespace_count
        else:
            start_idx = namespace_count * batch

        last_idx = start_idx + namespace_count - 1

        monitoring_start = csv_data['monitoring_start'][start_idx]
        monitoring_now = csv_data['monitoring_now'][last_idx]
        monitoring_second = csv_data['monitoring_second'][last_idx]

        result_row = [monitoring_start, monitoring_now, monitoring_second]

        # Sum stats for each measurement column across the namespace
        for col_name in column_names[3:]:
            col_values = csv_data[col_name]
            total_sum = 0
            for idx in range(start_idx, last_idx + 1):
                total_sum += int(col_values[idx])
            result_row.append(total_sum)

        result_rows.append(result_row)

    with open(out, 'w', encoding='utf-8') as file_writer:
        file_writer.write(",".join(column_names))
        file_writer.write("\n")
        for data in result_rows:
            file_writer.write(",".join([str(x) for x in data]))
            file_writer.write("\n")
        file_writer.flush()
        file_writer.close()


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Please provide path to benchmark-stats.csv and output file")
        sys.exit(1)
    main(sys.argv[1], sys.argv[2])
