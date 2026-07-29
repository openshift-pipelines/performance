#!/usr/bin/env python3
"""Generate a KB article from comparison/benchmark JSON using OpenAI API.

Takes the output of generate_comparison.py (JSON + prompt template) and
calls an LLM to produce the final KB article as a markdown file.

Usage:
    # From comparison output:
    python generate_article.py \\
        --input output/comparison_v1.22_vs_v1.23.json \\
        --output output/kb_article_v1.22_vs_v1.23.md

    # From benchmark output:
    python generate_article.py \\
        --input output/benchmark_v1.23.json \\
        --output output/kb_article_v1.23.md

    # Custom model or API key env var:
    python generate_article.py \\
        --input output/comparison_v1.22_vs_v1.23.json \\
        --model gpt-4o \\
        --api-key-env OPENAI_API_KEY

Environment:
    OPENAI_API_KEY: OpenAI API key (or use --api-key-env to specify a different var)
"""

import argparse
import json
import logging
import os
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-8s %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger(__name__)

DEFAULT_MODEL = "gpt-4o"
DEFAULT_API_KEY_ENV = "OPENAI_API_KEY"


def detect_mode(data):
    """Detect whether the JSON is comparison or benchmark data."""
    meta = data.get("meta", {})
    if meta.get("mode") == "benchmark":
        return "benchmark"
    if "version_a" in meta and "version_b" in meta:
        return "comparison"
    if "version" in meta:
        return "benchmark"
    return "comparison"


def load_prompt_template(mode):
    """Load the appropriate prompt template based on mode."""
    if mode == "benchmark":
        template_path = SCRIPT_DIR / "prompt_template_benchmark.md"
    else:
        template_path = SCRIPT_DIR / "prompt_template.md"

    if not template_path.exists():
        logger.error("Prompt template not found: %s", template_path)
        sys.exit(1)

    return template_path.read_text()


def build_prompt(template, data, mode):
    """Replace placeholders in the template with actual data."""
    meta = data.get("meta", {})
    data_json = json.dumps(data, indent=2, default=str)

    if mode == "benchmark":
        prompt = template.replace("{{VERSION}}", meta.get("version", "unknown"))
        prompt = prompt.replace("{{BENCHMARK_DATA}}", data_json)
    else:
        prompt = template.replace("{{VERSION_A}}", meta.get("version_a", "unknown"))
        prompt = template.replace("{{VERSION_B}}", meta.get("version_b", "unknown"))
        prompt = prompt.replace("{{COMPARISON_DATA}}", data_json)

    return prompt


def call_openai(prompt, model, api_key):
    """Call OpenAI API and return the generated article text."""
    try:
        from openai import OpenAI
    except ImportError:
        logger.error("openai package not installed. Run: pip install openai")
        sys.exit(1)

    client = OpenAI(api_key=api_key)

    logger.info("Calling OpenAI API (model=%s)...", model)
    logger.info("Prompt length: %d characters", len(prompt))

    try:
        response = client.chat.completions.create(
            model=model,
            messages=[
                {
                    "role": "system",
                    "content": (
                        "You are a senior performance engineer at Red Hat. "
                        "You write clear, professional, customer-facing KB articles. "
                        "Follow the instructions in the user message exactly."
                    ),
                },
                {
                    "role": "user",
                    "content": prompt,
                },
            ],
            temperature=0.3,
            max_tokens=16000,
        )
    except Exception as e:
        logger.error("OpenAI API call failed: %s", e)
        sys.exit(1)

    article = response.choices[0].message.content
    usage = response.usage

    logger.info(
        "API response received: %d tokens (prompt=%d, completion=%d)",
        usage.total_tokens,
        usage.prompt_tokens,
        usage.completion_tokens,
    )

    return article


def main():
    parser = argparse.ArgumentParser(
        description="Generate a KB article from comparison/benchmark JSON using OpenAI."
    )
    parser.add_argument(
        "--input", required=True,
        help="Path to comparison or benchmark JSON file"
    )
    parser.add_argument(
        "--output", default=None,
        help="Output markdown file path (default: auto-generated from input)"
    )
    parser.add_argument(
        "--model", default=DEFAULT_MODEL,
        help=f"OpenAI model to use (default: {DEFAULT_MODEL})"
    )
    parser.add_argument(
        "--api-key-env", default=DEFAULT_API_KEY_ENV,
        help=f"Environment variable containing the API key (default: {DEFAULT_API_KEY_ENV})"
    )

    args = parser.parse_args()

    # Load input JSON
    input_path = Path(args.input)
    if not input_path.exists():
        logger.error("Input file not found: %s", input_path)
        sys.exit(1)

    with open(input_path) as f:
        data = json.load(f)

    # Detect mode
    mode = detect_mode(data)
    logger.info("Detected mode: %s", mode)

    # Build prompt
    template = load_prompt_template(mode)
    prompt = build_prompt(template, data, mode)

    # Get API key
    api_key = os.environ.get(args.api_key_env, "")
    if not api_key:
        logger.error(
            "API key not set. Export %s or use --api-key-env.",
            args.api_key_env,
        )
        sys.exit(1)

    # Call LLM
    article = call_openai(prompt, args.model, api_key)

    # Determine output path
    if args.output:
        output_path = Path(args.output)
    else:
        output_path = input_path.with_suffix(".md")
        stem = input_path.stem
        if stem.startswith("comparison_"):
            output_path = input_path.parent / f"kb_article_{stem.replace('comparison_', '')}.md"
        elif stem.startswith("benchmark_"):
            output_path = input_path.parent / f"kb_article_{stem.replace('benchmark_', '')}.md"
        else:
            output_path = input_path.parent / f"kb_article_{stem}.md"

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(article)

    logger.info("KB article written to %s", output_path)
    print(f"\nArticle generated: {output_path}")
    print(f"Word count: ~{len(article.split())}")


if __name__ == "__main__":
    main()
