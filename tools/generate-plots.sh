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

source "$(dirname "$0")/lib.sh"

start_dir="$1"
output_dir="$2"
separate_graphs=true

if ! type -p gnuplot; then
    fatal "Please install GnuPlot"
fi

if [ -z "$start_dir" ] || [ -z "$output_dir" ]; then
    fatal "Either start directory or output directory not provied"
fi
if [ ! -d "$start_dir" ] || [ ! -d "$output_dir" ]; then
    fatal "Either start directory or output directory does not exist"
fi


function _get_title() {
    # E.g. let's title "artifacts/run-100-10/monitoring-collection-raw-data-dir/" as "run-100-10"
    basename "$( echo "$1" | sed 's|/\?monitoring-collection-raw-data-dir/\?||' )"
}


info "Looking for data in $start_dir"

mydirs="$( find "$start_dir" -type d -name monitoring-collection-raw-data-dir | sort )"
mydirs_count=$( echo "$mydirs" | wc -l )
myfiles="$( find $mydirs -maxdepth 1 -name \*.csv -printf "%f\n" | sort -u )"
myfiles_count=$( echo "$myfiles" | wc -l )
myoutput="$output_dir/dashboard.html"
myoutput_width=$(( 1920 - 30 ))   # my screen horizontal resolution minus some buffer :-)
mkdir -p "$output_dir/graphs/"

info "Found $mydirs_count directories with $myfiles_count unique CSV files"

echo "<html><head><title>Generated $( date --utc -Ins )</title></head><body>" >"$myoutput"

for f in $myfiles; do
    ff="$( basename "$f" .csv )"

    script="
        set datafile sep ','
        set key autotitle columnhead   # basically just to skip first line
        set style data lines
        set title '$ff'
        set terminal pngcairo linewidth 2
        set key noenhanced   # do not interpret underscores as text formatting
        set title noenhanced"
    output_width=$(( myoutput_width / mydirs_count ))

    if $separate_graphs; then
        echo "<h2>$ff</h2>" >>"$myoutput"
        echo "<table><tr>" >>"$myoutput"

        for d in $mydirs; do
            title=$( _get_title "$d" )
            output="$ff-$( echo "$title" | sed 's/[^a-zA-Z0-9-]/_/g' ).png"
            script_one="$script\nset output '$output_dir/graphs/$output'\nplot"
            script_one+=" '$d/$f' title '$title',"

            echo -e "$script_one" | gnuplot || true

            echo "<td><img src='graphs/$output' alt='Graph for $ff and $title' width='$output_width'/></td>" >>"$myoutput"
        done

        echo "</tr></table>" >>"$myoutput"
    else
        output="$ff.png"
        script+="\nset output '$output_dir/graphs/$output'"
        script+="\nplot"
        for d in $mydirs; do
            title=$( _get_title "$d" )
            script="$script '$d/$f' title '$title',"
        done

        echo -e "$script" | gnuplot

        echo "<h2>$ff</h2><img src='graphs/$output' alt='Graph for $ff'/>" >>"$myoutput"
    fi
done

echo "</body></html>" >>"$myoutput"

info "Dumped dashboard to $myoutput"
