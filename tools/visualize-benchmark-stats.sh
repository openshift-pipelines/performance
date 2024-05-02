#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

data_file="${1}"

{
    echo -n "
        set datafile sep ','
        set key autotitle columnhead   # basically just to skip first line which contains header
        set xdata time
        set timefmt '%Y-%m-%dT%H:%M:%S.000000+00:00'
        set style data lines
        set title 'PipelineRuns $data_file'
        set terminal pngcairo linewidth 1
        set key noenhanced autotitle columnhead  # do not interpret underscores as text formatting
        set title noenhanced
        set xlabel 'Time'
        set ylabel 'Count'
        set output 'benchmark-stats-pipelineruns.png'
        plot"
    echo -n " '$data_file' using 2:4 title 'prs_total' linewidth 2,"
    echo -n " '$data_file' using 2:5 title 'prs_pending' linewidth 2,"
    echo -n " '$data_file' using 2:6 title 'prs_running' linewidth 2,"
    echo -n " '$data_file' using 2:7 title 'prs_finished' linewidth 2,"
    echo -n " '$data_file' using 2:8 title 'prs_signed_true' linewidth 2,"
    echo -n " '$data_file' using 2:10 title 'prs_finalizers_present' linewidth 2,"
    echo -n " '$data_file' using 2:14 title 'prs_deleted' linewidth 2,"
    echo -n " '$data_file' using 2:15 title 'prs_terminated' linewidth 2,"
} | gnuplot

{
    echo -n "
        set datafile sep ','
        set key autotitle columnhead   # basically just to skip first line which contains header
        set xdata time
        set timefmt '%Y-%m-%dT%H:%M:%S.000000+00:00'
        set style data lines
        set title 'TaskRuns $data_file'
        set terminal pngcairo linewidth 1
        set key noenhanced autotitle columnhead  # do not interpret underscores as text formatting
        set title noenhanced
        set xlabel 'Time'
        set ylabel 'Count'
        set output 'benchmark-stats-taskrunsruns.png'
        plot"
    echo -n " '$data_file' using 2:16 title 'trs_total' linewidth 2,"
    echo -n " '$data_file' using 2:17 title 'trs_pending' linewidth 2,"
    echo -n " '$data_file' using 2:18 title 'trs_running' linewidth 2,"
    echo -n " '$data_file' using 2:19 title 'trs_finished' linewidth 2,"
    echo -n " '$data_file' using 2:20 title 'trs_signed_true' linewidth 2,"
    echo -n " '$data_file' using 2:22 title 'trs_finalizers_present' linewidth 2,"
    echo -n " '$data_file' using 2:24 title 'trs_deleted' linewidth 2,"
    echo -n " '$data_file' using 2:25 title 'trs_terminated' linewidth 2,"
} | gnuplot
