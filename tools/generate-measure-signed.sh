#!/bin/bash

# Looks for direcotries "monitoring-collection-raw-data-dir" and CSV
# files in these. Then generates HTML document with graphs, one graph
# for all files of a given name.
#
# First parameter is direcotry where to look for
# "monitoring-collection-raw-data-dir" direcotries.
#
# Second parameter is a direcotry where to put the output.

set -o nounset
set -o errexit
set -o pipefail

source "$(dirname "$0")/../ci-scripts/lib.sh"

output_dir="signatures/"
mkdir -p "$output_dir/graphs/"
columns_to_names="
2 all
3 succeeded
4 signed true
5 signed false
6 unsigned
7 guessed avg
8 guessed avg count
9 latency created succeeded
10 latency succeeded signed
"
myoutput="$output_dir/dashboard.html"

function script_base() {
    local title="$1"
    local output_relative="$2"
    echo -n "
        set datafile sep ','
        set key autotitle columnhead   # basically just to skip first line
        set style data lines
        set title '$title'
        set terminal pngcairo linewidth 2
        set key noenhanced   # do not interpret underscores as text formatting
        set title noenhanced
        set output '$output_dir/$output_relative'
        plot"
}
function html_img() {
    local title="$1"
    local output_relative="$2"
    echo "<img src='$output_relative' alt='$title' width='500'/>" >>"$myoutput"
}

echo "<html><head><title>Generated $( date --utc -Ins )</title></head><body>" >"$myoutput"

for path_grepper in "run-1000-20" "run-1000-40" "run-1000-60" "run-1000-80" "run-1000-100"; do
    info "Working with path grepper $path_grepper"
    echo "<h1>Graphs for $path_grepper</h1>" >>"$myoutput"
    data_files=$( find . -type f -name measure-signed.csv | grep "$path_grepper" )
    path_title_part=$( echo "$path_grepper" | sed 's/[^a-zA-Z0-9]/_/g' )
    for column in 2 3 4 5 7 9 10; do
        column_name=$( echo "$columns_to_names" | grep "^$column " | sed 's/^[0-9]\+ //' )
        column_title_part=$( echo "$column_name" | sed 's/[^a-zA-Z0-9]/_/g' )
        output_file="graphs/graphs-$path_title_part-$column_title_part.png"
        script="$( script_base "$path_grepper - $column_name" "$output_file" )"
        for f in $data_files; do
            title=$( echo "$f" | cut -d '/' -f 2 )
            script="$script '$f' using $column title '$title',"
        done

        echo -e "$script" | gnuplot

       html_img "Graph for $path_grepper - $column_name" "$output_file" >>"$myoutput"
    done

    info "Creating measure-signed graphs"
    "$(dirname "$0")"/generate-measure-signed-avg.py $( find . -type f -name measure-signed.csv | grep "$path_grepper" ) "$output_dir/measure-signed-$path_title_part.csv"
    output_file="graphs/graphs-$path_title_part-measure-signed.png"
    script="$( script_base "$path_grepper - measure-signed" "$output_file" )"
    script="$script '$output_dir/measure-signed-$path_title_part.csv' using 2,"
    script="$script '$output_dir/measure-signed-$path_title_part.csv' using 3,"
    script="$script '$output_dir/measure-signed-$path_title_part.csv' using 4,"
    script="$script '$output_dir/measure-signed-$path_title_part.csv' using 5"
    echo -e "$script" | gnuplot
    html_img "Graph for $path_grepper - measure-signed" "$output_file" >>"$myoutput"

    output_file="graphs/graphs-$path_title_part-measure-signed-guessed-avg.png"
    script="$( script_base "$path_grepper - measure-signed guessed avg" "$output_file" )"
    script="$script '$output_dir/measure-signed-$path_title_part.csv' using 7"
    echo -e "$script" | gnuplot
    html_img "Graph for $path_grepper - measure-signed guessed avg" "$output_file" >>"$myoutput"
done

info "Working on summary"
echo "<h1>Summary</h1>" >>"$myoutput"
output_file="graphs/graphs-summary-measure-signed-all.png"
script="$( script_base "summary - measure-signed all" "$output_file" )"
for path_grepper in "run-1000-20" "run-1000-40" "run-1000-60" "run-1000-80" "run-1000-100"; do
    path_title_part=$( echo "$path_grepper" | sed 's/[^a-zA-Z0-9]/_/g' )
    script="$script '$output_dir/measure-signed-$path_title_part.csv' using 2 title '$path_grepper',"
done
echo -e "$script" | gnuplot
html_img "Graph for summary - measure-signed all" "$output_file" >>"$myoutput"

output_file="graphs/graphs-summary-measure-signed-succeeded.png"
script="$( script_base "summary - measure-signed succeeded" "$output_file" )"
for path_grepper in "run-1000-20" "run-1000-40" "run-1000-60" "run-1000-80" "run-1000-100"; do
    path_title_part=$( echo "$path_grepper" | sed 's/[^a-zA-Z0-9]/_/g' )
    script="$script '$output_dir/measure-signed-$path_title_part.csv' using 3 title '$path_grepper',"
done
echo -e "$script" | gnuplot
html_img "Graph for summary - measure-signed succeeded" "$output_file" >>"$myoutput"

output_file="graphs/graphs-summary-measure-signed-signed-true.png"
script="$( script_base "summary - measure-signed signed true" "$output_file" )"
for path_grepper in "run-1000-20" "run-1000-40" "run-1000-60" "run-1000-80" "run-1000-100"; do
    path_title_part=$( echo "$path_grepper" | sed 's/[^a-zA-Z0-9]/_/g' )
    script="$script '$output_dir/measure-signed-$path_title_part.csv' using 4 title '$path_grepper',"
done
echo -e "$script" | gnuplot
html_img "Graph for summary - measure-signed signed true" "$output_file" >>"$myoutput"

output_file="graphs/graphs-summary-measure-signed-signed-false.png"
script="$( script_base "summary - measure-signed signed false" "$output_file" )"
for path_grepper in "run-1000-20" "run-1000-40" "run-1000-60" "run-1000-80" "run-1000-100"; do
    path_title_part=$( echo "$path_grepper" | sed 's/[^a-zA-Z0-9]/_/g' )
    script="$script '$output_dir/measure-signed-$path_title_part.csv' using 5 title '$path_grepper',"
done
echo -e "$script" | gnuplot
html_img "Graph for summary - measure-signed signed true" "$output_file" >>"$myoutput"

output_file="graphs/graphs-summary-measure-signed-guessed-avg.png"
script="$( script_base "summary - measure-signed guessed avg" "$output_file" )"
for path_grepper in "run-1000-20" "run-1000-40" "run-1000-60" "run-1000-80" "run-1000-100"; do
    path_title_part=$( echo "$path_grepper" | sed 's/[^a-zA-Z0-9]/_/g' )
    script="$script '$output_dir/measure-signed-$path_title_part.csv' using 7 title '$path_grepper',"
done
echo -e "$script" | gnuplot
html_img "Graph for summary - measure-signed guessed avg" "$output_file" >>"$myoutput"

output_file="graphs/graphs-summary-measure-latency-created-succeeded.png"
script="$( script_base "summary - measure-signed latency created succeeded" "$output_file" )"
for path_grepper in "run-1000-20" "run-1000-40" "run-1000-60" "run-1000-80" "run-1000-100"; do
    path_title_part=$( echo "$path_grepper" | sed 's/[^a-zA-Z0-9]/_/g' )
    script="$script '$output_dir/measure-signed-$path_title_part.csv' using 9 title '$path_grepper',"
done
echo -e "$script" | gnuplot
html_img "Graph for summary - measure-signed latency created succeeded" "$output_file" >>"$myoutput"

output_file="graphs/graphs-summary-measure-signed-latency-succeeded-signed.png"
script="$( script_base "summary - measure-signed latency succeeded signed" "$output_file" )"
for path_grepper in "run-1000-20" "run-1000-40" "run-1000-60" "run-1000-80" "run-1000-100"; do
    path_title_part=$( echo "$path_grepper" | sed 's/[^a-zA-Z0-9]/_/g' )
    script="$script '$output_dir/measure-signed-$path_title_part.csv' using 10 title '$path_grepper',"
done
echo -e "$script" | gnuplot
html_img "Graph for summary - measure-signed latency succeeded signed" "$output_file" >>"$myoutput"

echo "</body></html>" >>"$myoutput"

info "Dumped dashboard to $myoutput"
