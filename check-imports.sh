#!/bin/bash

set -euo pipefail

# Default values
FUNCTION=""
PACKAGE=""
EXTENSIONS="js,ts,tsx"
DIRECTORIES=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] <directories...>

Find files using a function without importing it from a specific package.

Options:
  -f, --function <name>    Function name to search for (required)
  -p, --package <name>     Package it should be imported from (required)
  -e, --extensions <list>  Comma-separated file extensions (default: js,ts,tsx)
  -h, --help               Show this help message

Examples:
  $(basename "$0") -f=_x -p=@wordpress/i18n src
  $(basename "$0") --function _x --package @wordpress/i18n src vite/src
  $(basename "$0") -f=__ -p=@wordpress/i18n -e=js,jsx src
EOF
  exit "${1:-0}"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f=*|--function=*)
      FUNCTION="${1#*=}"
      shift
      ;;
    -f|--function)
      FUNCTION="$2"
      shift 2
      ;;
    -p=*|--package=*)
      PACKAGE="${1#*=}"
      shift
      ;;
    -p|--package)
      PACKAGE="$2"
      shift 2
      ;;
    -e=*|--extensions=*)
      EXTENSIONS="${1#*=}"
      shift
      ;;
    -e|--extensions)
      EXTENSIONS="$2"
      shift 2
      ;;
    -h|--help)
      usage 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage 1
      ;;
    *)
      DIRECTORIES+=("$1")
      shift
      ;;
  esac
done

# Validate required arguments
if [[ -z "$FUNCTION" ]]; then
  echo "Error: --function is required" >&2
  usage 1
fi

if [[ -z "$PACKAGE" ]]; then
  echo "Error: --package is required" >&2
  usage 1
fi

if [[ ${#DIRECTORIES[@]} -eq 0 ]]; then
  echo "Error: At least one directory is required" >&2
  usage 1
fi

# Escape special regex characters in package name
PACKAGE_ESCAPED=$(printf '%s' "$PACKAGE" | sed 's/[[\.*^$()+?{|]/\\&/g')

# Find files
count=0
while IFS= read -r file; do
  if ! rg -q "import.*\b${FUNCTION}\b.*from\s*['\"]${PACKAGE_ESCAPED}['\"]" "$file"; then
    echo "$file"
    ((count++))
  fi
done < <(rg -l "\b${FUNCTION}\b" --glob "**/*.{${EXTENSIONS}}" "${DIRECTORIES[@]}" 2>/dev/null)

# Summary
if [[ $count -eq 0 ]]; then
  echo "✓ All files using '${FUNCTION}' import it from '${PACKAGE}'" >&2
else
  echo "" >&2
  echo "Found ${count} file(s) using '${FUNCTION}' without importing from '${PACKAGE}'" >&2
  exit 1
fi