#!/usr/bin/env bash

# =============================================================================
# Horreum API Integration Script Wrapper
# =============================================================================
#
# This script provides a convenient wrapper for the horreum_api.py 
# Python script with environment variable validation and helpful error messages.
#
# Prerequisites:
# - horreum_api package installed via pip
# - horreum_fields_config.yaml configuration file present
#
# Installation:
# pip install git+https://github.com/redhat-performance/opl.git@horreum-api
#
# =============================================================================

set -e  # Exit on any error

# Script configuration
SCRIPT_NAME=$(basename "$0")
CONFIG_FILE_DEFAULT="horreum_fields_config.yaml"
REQUIRED_COMMAND="horreum_api.py"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
error() {
    echo -e "${RED}ERROR: $1${NC}" >&2
}

warning() {
    echo -e "${YELLOW}WARNING: $1${NC}" >&2
}

info() {
    echo -e "${BLUE}INFO: $1${NC}"
}

success() {
    echo -e "${GREEN}SUCCESS: $1${NC}"
}

show_usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

This script wraps horreum_api.py with environment variable validation
and provides helpful error messages for missing requirements.

OPTIONS:
    -c, --config-file FILE    Path to YAML configuration file
    -h, --help               Show this help message
    --execute                Disable dry-run mode (execute changes)
    --dry-run                Enable dry-run mode (default)

REQUIRED ENVIRONMENT VARIABLES:
    HORREUM_URL              Horreum instance URL
                             Example: export HORREUM_URL="http://localhost:8080"

    HORREUM_API_KEY          API key for authentication (recommended)
                             Example: export HORREUM_API_KEY="HUSR_00000000_0000_0000_0000_000000000000"
                             
    OR
    
    HORREUM_TOKEN            Bearer token for authentication (legacy)
                             Example: export HORREUM_TOKEN="your-bearer-token"

OPTIONAL ENVIRONMENT VARIABLES:
    HORREUM_CONFIG_FILE      Path to configuration file
                             Default: horreum_fields_config.yaml
                             Example: export HORREUM_CONFIG_FILE="my_config.yaml"

    HORREUM_SCHEMA_ID        Use existing schema ID (skip schema creation)
                             Example: export HORREUM_SCHEMA_ID="285"

    HORREUM_TEST_ID          Use existing test ID (skip test creation)  
                             Example: export HORREUM_TEST_ID="399"

    SKIP_LABELS              Skip label creation entirely
                             Values: true|false (default: false)
                             Example: export SKIP_LABELS=true

    CLEANUP_LABELS           Remove labels not in configuration
                             Values: true|false (default: true)
                             Example: export CLEANUP_LABELS=false

    CLEANUP_VARIABLES        Remove variables not in configuration
                             Values: true|false (default: true)
                             Example: export CLEANUP_VARIABLES=false

    DRY_RUN                  Preview changes without executing them
                             Values: true|false (default: true)
                             Example: export DRY_RUN=false

EXAMPLES:
    # Basic usage with dry-run (safe preview)
    export HORREUM_URL="http://localhost:8080"
    export HORREUM_API_KEY="HUSR_00000000_0000_0000_0000_000000000000"
    $SCRIPT_NAME

    # Execute changes (disable dry-run)
    $SCRIPT_NAME --execute

    # Use custom configuration file
    $SCRIPT_NAME --config-file my_fields_config.yaml

    # Use existing resources to avoid creation
    export HORREUM_SCHEMA_ID="285"
    export HORREUM_TEST_ID="399"
    $SCRIPT_NAME --execute

    # Skip label operations
    export SKIP_LABELS=true
    $SCRIPT_NAME

    # Disable cleanup operations
    export CLEANUP_LABELS=false
    export CLEANUP_VARIABLES=false
    $SCRIPT_NAME --execute

EOF
}

check_command_available() {
    if ! command -v "$REQUIRED_COMMAND" &> /dev/null; then
        error "Command '$REQUIRED_COMMAND' not found in PATH"
        error "Please install the horreum_api package:"
        error "  pip install git+https://github.com/redhat-performance/opl.git@horreum-api"
        error ""
        error "Or if already installed, ensure it's in your PATH:"
        error "  which $REQUIRED_COMMAND"
        return 1
    fi
    return 0
}

check_required_env_vars() {
    local missing_vars=()
    
    # Check for Horreum URL
    if [[ -z "${HORREUM_URL:-}" ]]; then
        missing_vars+=("HORREUM_URL")
    fi
    
    # Check for authentication (either API key or token)
    if [[ -z "${HORREUM_API_KEY:-}" ]] && [[ -z "${HORREUM_TOKEN:-}" ]]; then
        missing_vars+=("HORREUM_API_KEY or HORREUM_TOKEN")
    fi
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        error "Missing required environment variables:"
        for var in "${missing_vars[@]}"; do
            error "  - $var"
        done
        error ""
        error "Please set the required environment variables:"
        error "  export HORREUM_URL=\"http://your-horreum-instance:8080\""
        error "  export HORREUM_API_KEY=\"HUSR_00000000_0000_0000_0000_000000000000\""
        error ""
        error "Run '$SCRIPT_NAME --help' for more information."
        return 1
    fi
    
    return 0
}

check_config_file() {
    # Determine which config file to check
    local config_file="${HORREUM_CONFIG_FILE:-$CONFIG_FILE_DEFAULT}"
    
    # If config file was passed as argument, use that
    if [[ -n "${config_file_arg:-}" ]]; then
        config_file="$config_file_arg"
    fi
    
    if [[ ! -f "$config_file" ]]; then
        error "Configuration file not found: $config_file"
        error ""
        error "Please create a YAML configuration file with the following structure:"
        error ""
        error "global:"
        error "  owner: \"your-team\""
        error "  access: \"PUBLIC\""
        error ""
        error "test:"
        error "  name: \"My Performance Test\""
        error "  owner: \"your-team\""
        error "  folder: \"performance-tests\""
        error "  description: \"Performance regression test\""
        error ""
        error "schema:"
        error "  name: \"My Test Schema\""
        error "  owner: \"your-team\""
        error "  uri: \"urn:my-schema:1.0\""
        error ""
        error "fields:"
        error "  - name: \"throughput\""
        error "    jsonpath: \"$.metrics.throughput\""
        error "    description: \"Request throughput\""
        error "    filtering: true"
        error "    metrics: true"
        error "    change_detection_group: \"performance\""
        error ""
        error "change_detection_defaults:"
        error "  model: \"relativeDifference\""
        error "  threshold: 0.1"
        error "  window: 10"
        error "  min_previous: 5"
        error "  aggregation: \"mean\""
        error ""
        error "See the documentation for complete configuration examples."
        return 1
    fi
    
    info "Using configuration file: $config_file"
    return 0
}

set_optional_env_defaults() {
    # Set default values for optional environment variables if not already set
    
    # DRY_RUN defaults to true (safe preview mode)
    export DRY_RUN="${DRY_RUN:-true}"
    
    # CLEANUP_LABELS defaults to true
    export CLEANUP_LABELS="${CLEANUP_LABELS:-true}"
    
    # CLEANUP_VARIABLES defaults to true
    export CLEANUP_VARIABLES="${CLEANUP_VARIABLES:-true}"
    
    # SKIP_LABELS defaults to false
    export SKIP_LABELS="${SKIP_LABELS:-false}"
}

show_env_summary() {
    info "Environment Configuration Summary:"
    info "=================================="
    info "HORREUM_URL: ${HORREUM_URL}"
    info "HORREUM_API_KEY: ${HORREUM_API_KEY:+***set***}${HORREUM_API_KEY:-not set}"
    info "HORREUM_TOKEN: ${HORREUM_TOKEN:+***set***}${HORREUM_TOKEN:-not set}"
    info "HORREUM_CONFIG_FILE: ${HORREUM_CONFIG_FILE:-$CONFIG_FILE_DEFAULT}"
    info "HORREUM_SCHEMA_ID: ${HORREUM_SCHEMA_ID:-not set (will create new)}"
    info "HORREUM_TEST_ID: ${HORREUM_TEST_ID:-not set (will create new)}"
    info "DRY_RUN: ${DRY_RUN}"
    info "SKIP_LABELS: ${SKIP_LABELS}"
    info "CLEANUP_LABELS: ${CLEANUP_LABELS}"
    info "CLEANUP_VARIABLES: ${CLEANUP_VARIABLES}"
    info "=================================="
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        warning "DRY RUN MODE ENABLED - No changes will be made"
        warning "Use --execute flag or export DRY_RUN=false to execute changes"
    else
        warning "DRY RUN DISABLED - Changes will be executed!"
    fi
    echo ""
}

main() {
    local config_file_arg=""
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config-file)
                config_file_arg="$2"
                shift 2
                ;;
            --execute)
                export DRY_RUN=false
                shift
                ;;
            --dry-run)
                export DRY_RUN=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                error "Run '$SCRIPT_NAME --help' for usage information."
                exit 1
                ;;
        esac
    done
    
    info "Horreum API Integration Script Wrapper"
    info "======================================"
    
    # Check if the Python command is available
    if ! check_command_available; then
        exit 1
    fi
    
    # Check required environment variables
    if ! check_required_env_vars; then
        exit 1
    fi
    
    # Set optional environment variable defaults
    set_optional_env_defaults
    
    # Check configuration file exists
    if ! check_config_file; then
        exit 1
    fi
    
    # Show environment summary
    show_env_summary
    
    # Build command arguments
    local cmd_args=()
    
    if [[ -n "${config_file_arg}" ]]; then
        cmd_args+=("--config-file" "$config_file_arg")
    fi
    
    # Execute the Python script
    info "Executing: $REQUIRED_COMMAND ${cmd_args[*]}"
    info "======================================"
    
    if "$REQUIRED_COMMAND" "${cmd_args[@]}"; then
        success "Horreum integration completed successfully!"
        
        if [[ "${DRY_RUN}" == "true" ]]; then
            info ""
            info "This was a DRY RUN - no changes were made."
            info "To execute the changes, run:"
            info "  $SCRIPT_NAME --execute"
            info "or set: export DRY_RUN=false"
        fi
    else
        error "Horreum integration failed!"
        exit 1
    fi
}

# Run main function with all arguments
main "$@"
