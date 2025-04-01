#!/bin/bash

# Display usage information
usage() {
    echo "Usage: $(basename "$0") [OPTIONS] [TAG_MESSAGE]"
    echo
    echo "Create and push a test tag with timestamp and branch name."
    echo
    echo "Options:"
    echo "  --name VALUE     Use custom name instead of branch name"
    echo "  -h, --help       Display this help message and exit"
    echo
    echo "Arguments:"
    echo "  TAG_MESSAGE      Optional message for the tag (creates an annotated tag)"
    echo
    echo "Examples:"
    echo "  $(basename "$0")                     # Use current branch name"
    echo "  $(basename "$0") --name demo         # Use custom name 'demo'"
    echo "  $(basename "$0") 'QA build for testing'   # With message"
    echo "  $(basename "$0") --name rc 'Release candidate'  # Custom name with message"
    echo
    echo "The resulting tag will be in the format: test-YYYYMMDDTHHMMSS-name"
    echo "All names will be converted to lowercase with only a-z, 0-9, and hyphens."
    echo
    exit 0
}

# Default values
USE_CUSTOM_NAME=false
CUSTOM_NAME=""
TAG_MESSAGE=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            ;;
        --name)
            USE_CUSTOM_NAME=true
            if [[ $# -gt 1 ]]; then
                CUSTOM_NAME="$2"
                shift
            else
                echo "Error: --name requires a value"
                exit 1
            fi
            ;;
        *)
            # Any non-flag argument is treated as the tag message
            TAG_MESSAGE="$1"
            ;;
    esac
    shift
done

# Get current timestamp in the format YYYYMMDDTHHMMSS
TIMESTAMP=$(date +"%Y%m%dT%H%M%S")

# Function to sanitize name in a cross-platform way
sanitize_name() {
    local input="$1"
    # Convert to lowercase
    input=$(echo "$input" | tr '[:upper:]' '[:lower:]')
    # Replace spaces with hyphens
    input=$(echo "$input" | tr ' ' '-')
    
    # Remove non-allowed characters (compatible with both macOS and Linux)
    local temp_file=$(mktemp)
    echo "$input" > "$temp_file"
    LC_CTYPE=C tr -cd 'a-z0-9-\n' < "$temp_file" > "${temp_file}.2"
    local result=$(cat "${temp_file}.2")
    rm -f "$temp_file" "${temp_file}.2"
    
    echo "$result"
}

if [ "$USE_CUSTOM_NAME" = true ]; then
    # Process custom name
    NAME_PART=$(sanitize_name "$CUSTOM_NAME")
else
    # Get current branch name
    BRANCH_NAME=$(git rev-parse --abbrev-ref HEAD)
    
    # Remove any "patch/" prefix from branch name
    BRANCH_NAME=${BRANCH_NAME#patch/}
    
    # Replace any remaining slashes with hyphens to avoid issues with tag names
    BRANCH_NAME=${BRANCH_NAME//\//-}
    
    # Process branch name
    NAME_PART=$(sanitize_name "$BRANCH_NAME")
fi

# Create tag name
TAG_NAME="test-${TIMESTAMP}-${NAME_PART}"

if [ -n "$TAG_MESSAGE" ]; then
    echo "Creating test tag: $TAG_NAME"
    echo "With tag message: $TAG_MESSAGE"
else
    echo "Creating test tag: $TAG_NAME"
fi

# Create tag with or without a message
if [ -n "$TAG_MESSAGE" ]; then
    git tag -a "$TAG_NAME" -m "$TAG_MESSAGE" && git push && git push origin "$TAG_NAME"
else
    git tag "$TAG_NAME" && git push && git push origin "$TAG_NAME"
fi

echo "✅ Test tag created and pushed successfully."
