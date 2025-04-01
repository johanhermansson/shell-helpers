#!/bin/bash

# Display usage information
usage() {
    echo "Usage: $(basename "$0") [OPTIONS] [TAG_MESSAGE]"
    echo
    echo "Create and push a new semantic version tag."
    echo
    echo "Options:"
    echo "  --patch          Increment patch version (default)"
    echo "  --minor          Increment minor version and reset patch to 0"
    echo "  --major          Increment major version and reset minor and patch to 0"
    echo "  -h, --help       Display this help message and exit"
    echo
    echo "Arguments:"
    echo "  TAG_MESSAGE      Optional message for the tag (creates an annotated tag)"
    echo
    echo "Examples:"
    echo "  $(basename "$0")                     # Increment patch: 1.2.3 -> 1.2.4"
    echo "  $(basename "$0") --minor             # Increment minor: 1.2.3 -> 1.3.0"
    echo "  $(basename "$0") --major             # Increment major: 1.2.3 -> 2.0.0"
    echo "  $(basename "$0") 'Bug fix release'   # With message"
    echo "  $(basename "$0") --minor 'New features added'  # Minor with message"
    echo
    exit 0
}

# Parse arguments
INCREMENT_TYPE="patch"  # Default is patch increment
TAG_MESSAGE=""

# Check for help parameter first
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
fi

# Process first argument for increment type
if [[ "$1" == "--patch" || "$1" == "--minor" || "$1" == "--major" ]]; then
    INCREMENT_TYPE="${1#--}"  # Remove the -- prefix
    shift  # Remove the first argument
fi

# Any remaining argument is treated as the tag message
if [[ $# -gt 0 ]]; then
    TAG_MESSAGE="$*"  # Combine all remaining arguments as the message
fi

# Get the current version (latest semver tag)
CURRENT_VERSION=$(git tag -l | grep -E "^[0-9]+\.[0-9]+\.[0-9]+$" | sort -V | tail -n 1)

# Check if we found a current version
if [[ -z "$CURRENT_VERSION" ]]; then
    echo "Error: No existing semantic version tags found."
    echo "Create an initial version tag first (e.g., git tag 0.1.0)"
    exit 1
fi

# Calculate the new version based on increment type
if [[ "$INCREMENT_TYPE" == "minor" ]]; then
    # Increment minor version and reset patch to 0
    NEW_VERSION=$(echo "$CURRENT_VERSION" | awk -F. '{$2=$2+1; $3=0; print $1"."$2"."$3}')
elif [[ "$INCREMENT_TYPE" == "major" ]]; then
    # Increment major version and reset minor and patch to 0
    NEW_VERSION=$(echo "$CURRENT_VERSION" | awk -F. '{$1=$1+1; $2=0; $3=0; print $1"."$2"."$3}')
else
    # Increment patch version
    NEW_VERSION=$(echo "$CURRENT_VERSION" | awk -F. '{$3=$3+1; print $1"."$2"."$3}')
fi

# Create and push the new tag
echo "Creating new version tag: $NEW_VERSION (from $CURRENT_VERSION)"

if [[ -n "$TAG_MESSAGE" ]]; then
    echo "With tag message: $TAG_MESSAGE"
fi

# Create tag with or without a message
if [[ -n "$TAG_MESSAGE" ]]; then
    git tag -a "$NEW_VERSION" -m "$TAG_MESSAGE" && git push && git push origin "$NEW_VERSION"
else
    git tag "$NEW_VERSION" && git push && git push origin "$NEW_VERSION"
fi

echo "✅ Version $NEW_VERSION created and pushed successfully."
