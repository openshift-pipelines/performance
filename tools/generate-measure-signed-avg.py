#!/usr/bin/env python
# -*- coding: UTF-8 -*-

# Computes average of many given measure-signed.csv, per column and row

import sys
import csv


output_file = sys.argv[-1]   # last param is output file name
data = []
keys = ["all", "succeeded", "signed", "unsigned", "guessed avg", "guessed from count", "latency created succeeded", "latency succeeded signed"]

for file in sys.argv[1:-1]:   # first param is script name, last is output file name
    print(f"Loading file {file}")
    with open(file, "r") as fd:
        for i, row in enumerate(csv.DictReader(fd)):
            try:
                current = data[i]
            except IndexError:
                current = {
                    "sums": {k: 0.0 for k in keys},
                    "counts": {k: 0 for k in keys},
                }
                data.append(current)

            for key in keys:
                if row[key] != "":
                    current["sums"][key] += float(row[key])
                current["counts"][key] += 1

print(f"Saving summary to {output_file}")
with open(output_file, "w") as fd:
    csv_writer = csv.DictWriter(fd, ["date"] + keys)
    csv_writer.writeheader()
    for item in data:
        row = {"date": None}
        for key in keys:
            if item["counts"][key] == 0:
                row[key] = 0
            else:
                row[key] = item["sums"][key] / item["counts"][key]
        csv_writer.writerow(row)
