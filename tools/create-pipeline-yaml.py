#!/usr/bin/env python3
# -*- coding: UTF-8 -*-

import os
import sys
import time
import logging
import argparse

import jinja2

# Constants Flgas and Parameters
PIPELINE_TEMPLATE_DEFAULT_FILE = "pipeline.yaml.j2"

# Store global log object
logger = None

def setup_logger(stderr_log_lvl):
    """
    Create logger that logs to both stderr and log file but with different log level
    """
    # Remove all handlers from root logger if any
    logging.basicConfig(level=logging.NOTSET, handlers=[])
    # Change root logger level from WARNING (default) to NOTSET in order for all messages to be delegated.
    logging.getLogger().setLevel(logging.NOTSET)

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

def convert_jinja2_filename(j2_template_name:str):
    '''Convert "j2_template_name" into original filename (if its defined as .j2 format) otherwsie use ".out" extension'''
    if j2_template_name.endswith(".j2"):
        return j2_template_name[:-3]
    return j2_template_name + ".out"

def process_extra_data_argument(extra_data_arg:str):
    extra_data = {}
    for kv_pair in extra_data_arg.split(","):
        kv = kv_pair.split("=")
        # Remove trailing white-spaces
        key = kv[0].strip()
        val = kv[1].strip()
        extra_data[key] = val
    return extra_data

def populate_and_save_j2_template(args):
    '''Use jinja2 template to create test pipeline/task definition'''

    # Read template
    with open(args.file, 'r', encoding='utf-8') as template_file:
        template = template_file.read()

    # Load data
    data = {}
    if args.extra_data:
        data.update(process_extra_data_argument(args.extra_data))

    logger.debug("Data Arguments: %s", data)

    # Render the template
    jinja_env = jinja2.Environment(loader=jinja2.BaseLoader())
    rendered_template = jinja_env.from_string(template).render(data=data)

    # Save the rendered template to a file
    if not args.output:
        args.output = convert_jinja2_filename(args.file)

    with open(args.output, 'w', encoding='utf-8') as out_file:
        out_file.write(rendered_template)

    logger.info("Saved result: %s", args.output)

def main():
    global logger
    parser = argparse.ArgumentParser(
        prog="Pipeline YAML Generator",
        description="Dynamically populate and save jinja2 based pipeline/task templates",
    )
    parser.add_argument(
        "-d",
        "--debug",
        help="Debug output",
        action="store_true",
    )
    parser.add_argument(
        "--extra-data",
        help="Comma-seperated list of data values in K=V format",
        type=str,
    )
    parser.add_argument(
        "-f",
        "--file",
        default=PIPELINE_TEMPLATE_DEFAULT_FILE,
        help="File path to Jinja2 template",
        type=str,
    )
    parser.add_argument(
        "-o",
        "--output",
        help="""File location to save converted template (By default it uses original --file option value without .j2 extension)""",
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

    populate_and_save_j2_template(args)


if __name__ == "__main__":
    sys.exit(main())
