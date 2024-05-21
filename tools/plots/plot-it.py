#!/usr/bin/env python3
# -*- coding: UTF-8 -*-

import os
import sys
import glob
import time
import yaml
import logging
import argparse
from datetime import datetime

import pandas as pd
import matplotlib.pyplot as plt
from plot_it_formatters import Formatter

from pydantic import BaseModel
from typing import List, Optional

# Data Structure for plots

TYPE_TIMESERIES = "timeseries"

class Axis(BaseModel):
    name: Optional[str] = None
    formatter: Optional[str] = None
    data: Optional[str] = None

class Chart(BaseModel):
    type: str
    name: str
    show_events: bool = True
    data: List[str]
    xaxis: Optional[Axis] = Axis()
    yaxis: Axis

class Input(BaseModel):
    paths: List[str]

class Output(BaseModel):
    dir: str
    overwrite: bool

class Event(BaseModel):
    name: str
    timestamp: str
    format: str

class Plot(BaseModel):
    show_events: bool = False
    events: List[Event] = []
    input: Optional[Input]
    output: Optional[Output]
    charts: List[Chart] = []

# Constants Flgas and Parameters
DEFAULT_INPUT_FILE = "plot.yaml"

# Store global log object
logger = None
data_files = {}
formatter = Formatter()

def setup_logger(stderr_log_lvl):
    """
    Create logger that logs to both stderr and log file but with different log level
    """
    # Remove all handlers from root logger if any
    logging.basicConfig(level=logging.NOTSET, handlers=[])
    # Change root logger level from WARNING (default) to NOTSET in order for all messages to be delegated.
    logging.getLogger("plot-it").setLevel(logging.NOTSET)

    # Log message format
    formatter = logging.Formatter(
        "%(asctime)s %(name)s %(processName)s %(threadName)s %(levelname)s %(message)s"
    )
    formatter.converter = time.gmtime

    # Add stderr handler, with level INFO
    console = logging.StreamHandler()
    console.setFormatter(formatter)
    console.setLevel(stderr_log_lvl)
    logging.getLogger("root").addHandler(console)

    return logging.getLogger("root")
    
def convert_to_timestamp_series(series):
    try:
        return pd.to_datetime(series,unit='s')
    except:
        return pd.to_datetime(series)

def convert_to_datetime(date_string, date_format):
    return datetime.strptime(date_string, date_format)

# Input/Output Related Methods

def load_input_directory(plot:Plot):
    global data_files
    files = []
    for path in plot.input.paths:
        files = glob.glob(path)
        for file in files:
            # Take last part of the file path's filename
            filename = os.path.basename(file)

            # remove extension
            filename = "".join(filename.split(".")[:-1])

            data_files[filename] = file

    logger.debug("Found %d number of data files.", len(files))

def save_plot(fig, chart:Chart, plot:Plot):
    name = chart.name
    file_output = os.path.join(plot.output.dir, name + ".png")
    if (plot.output.overwrite is False and not os.path.exists(file_output)) or (plot.output.overwrite is True):
        fig.savefig(file_output)

# Chart related Methods

def plot_chart(chart:Chart, plot:Plot):
    global data_files

    # Create matplotlib figures and axis to draw data points    
    fig, ax = plt.subplots()

    # Set Title for the graph and axis
    if chart.name:
        fig.suptitle(chart.name, fontsize=12)

    if chart.xaxis.name:
        ax.set_xlabel(chart.xaxis.name, fontsize=10)
    else:
        if chart.type == TYPE_TIMESERIES:
            ax.set_xlabel("Timestamp", fontsize=10)

    if chart.yaxis.name:
        ax.set_ylabel(chart.yaxis.name, fontsize=10)

    # Set Formatters
    if chart.xaxis.formatter:
        ax.xaxis.set_major_formatter(formatter(chart.xaxis.formatter))
    else:
        if chart.type == TYPE_TIMESERIES:
            ax.xaxis.set_major_formatter(formatter("time_hour"))

    if chart.yaxis.formatter:
        ax.yaxis.set_major_formatter(formatter(chart.yaxis.formatter))

    # Plot Data Points
    min_y_val = float('inf')
    for data_name in chart.data:
        # Load Dataframe
        csv_file = data_files[data_name]
        df = pd.read_csv(csv_file)

        logger.debug("Data(%s) Shape - %s", data_name, df.shape)

        # Extract X-Axis Col Data
        x = df[chart.xaxis.data]

        if chart.type == TYPE_TIMESERIES:
            x = convert_to_timestamp_series(x)

        # Extract Y-Axis Col Data

        # Remaining type
        if chart.yaxis.data is None or chart.yaxis.data == "%":
            # Get remaining col names
            cols =  [col for col in df.columns if col != chart.xaxis.data]
            y = df[cols]
        else:
            y = df[chart.yaxis.data]

        min_y_val = min(min_y_val, y.min().iloc[0])

        # Plot chart
        ax.plot(x, y, label = y.columns[0])

    # Plot Events
    if chart.show_events is True or plot.show_events is True:
        for event in plot.events:
            date = convert_to_datetime(event.timestamp, event.format)
            label = event.name
            plt.axvline(
                x=date,
                color='r',
                linestyle='--',
                linewidth=1.5,
                alpha=0.5
            )
            plt.annotate(
                label,
                xy=(date, min_y_val),
                xytext=(8, 8),
                textcoords='offset points', color='r', fontsize=8,
            )

    # Show Legend
    if len(chart.data) > 1:
        ax.legend()

    # Save Chart into output
    save_plot(fig, chart, plot)

# Main Method

def plot_it(args):
    global data_files

    with open(args.file, 'r', encoding='utf-8') as f:
        plot_input_file = yaml.safe_load(f.read())
        plot_data = Plot(**plot_input_file)

    logger.info("Loaded plot input file: %s", args.file)
    logger.debug("Plot Data: %s", plot_data)

    # Cache available data directory files
    load_input_directory(plot_data)

    failed_chart_generations = 0

    for chart in plot_data.charts:
        try:
            plot_chart(chart, plot_data)
        except Exception as error:
            failed_chart_generations += 1
            logger.error("Unable to plot chart due to error: %s", error)
            logger.error("Chart Data: %s", chart)

    logger.info("Plot generation completed!")
    logger.info(
        "Total (%d) | Success (%d) | Failed (%d)",
        len(plot_data.charts),
        len(plot_data.charts) - failed_chart_generations,
        failed_chart_generations
    )

def main():
    global logger
    parser = argparse.ArgumentParser(
        prog="Plot it",
        description="Generate plots based on template",
    )
    parser.add_argument(
        "-d",
        "--debug",
        help="Debug output",
        action="store_true",
    )
    parser.add_argument(
        "-f",
        "--file",
        default=DEFAULT_INPUT_FILE,
        help="File path to plot YAML file",
        type=str,
    )
    parser.add_argument(
        "-v",
        "--verbose",
        help="Verbose output",
        action="store_true",
    )
    args = parser.parse_args()

    if args.debug:
        logger = setup_logger(logging.DEBUG)
    elif args.verbose:
        logger = setup_logger(logging.INFO)
    else:
        logger = setup_logger(logging.WARNING)

    logger.debug("Args: {%s}", args)

    plot_it(args)


if __name__ == "__main__":
    sys.exit(main())
