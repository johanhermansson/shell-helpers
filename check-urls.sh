#!/bin/bash

# Redirect Rules Checker
# This script checks if redirect rules defined in CSV format are correctly implemented
# Format: code,domain,path,redirect_to

# Default values
RULES_FILE=""
VERBOSE=false
TIMEOUT=10

# Function to display usage information
usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -f, --file FILE       Read redirect rules from FILE (CSV format)"
    echo "  -r, --rules RULES     Specify redirect rules as a string (CSV format)"
    echo "  -v, --verbose         Show detailed information for each check"
    echo "  -t, --timeout SEC     Set curl timeout in seconds (default: 10)"
    echo "  -h, --help            Display this help message"
    echo ""
    echo "CSV Format: code,domain,path,redirect_to"
    echo "Example: 301,www.example.com,^/old-page/?$,https://www.example.com/new-page/"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--file)
            RULES_FILE="$2"
            shift 2
            ;;
        -r|--rules)
            RULES="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -t|--timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Check if we have rules to process
if [[ -z "$RULES_FILE" && -z "$RULES" ]]; then
    echo "Error: No redirect rules specified. Use -f/--file or -r/--rules option."
    usage
    exit 1
fi

# If a file is specified, read rules from the file
if [[ -n "$RULES_FILE" ]]; then
    if [[ ! -f "$RULES_FILE" ]]; then
        echo "Error: Rules file '$RULES_FILE' not found."
        exit 1
    fi
    RULES=$(cat "$RULES_FILE")
fi

# Function to normalize URL for comparison
normalize_url() {
    local url="$1"
    # Remove trailing slash if present (for consistent comparison)
    url="${url%/}"
    # Return normalized URL
    echo "$url"
}

# Function to follow redirects and capture the redirect chain
follow_redirects() {
    local url="$1"
    local temp_file=$(mktemp)
    local redirect_chain=""
    local current_url="$url"
    local next_url=""
    local status_code=""
    local is_last=false
    
    while true; do
        # Make a HEAD request to get headers only (faster)
        curl -s -I -o "$temp_file" -w "%{http_code}" --max-time "$TIMEOUT" "$current_url" > /dev/null
        
        # Get status code
        status_code=$(grep -i "^HTTP/" "$temp_file" | tail -1 | awk '{print $2}')
        
        # If no status code was found, try a GET request instead
        if [[ -z "$status_code" ]]; then
            curl -s -o /dev/null -D "$temp_file" -w "%{http_code}" --max-time "$TIMEOUT" "$current_url" > /dev/null
            status_code=$(grep -i "^HTTP/" "$temp_file" | tail -1 | awk '{print $2}')
        fi
        
        # If still no status code, something went wrong
        if [[ -z "$status_code" ]]; then
            redirect_chain="$redirect_chain\nError: Could not connect to $current_url"
            break
        fi
        
        # Check if it's a redirect status code
        if [[ "$status_code" -ge 300 && "$status_code" -lt 400 ]]; then
            # Get redirect location
            next_url=$(grep -i "^location:" "$temp_file" | tail -1 | sed 's/^[Ll]ocation: *//g' | tr -d '\r\n')
            
            # If no next URL, break
            if [[ -z "$next_url" ]]; then
                redirect_chain="$redirect_chain\n$status_code $current_url -> No redirect location found"
                break
            fi
            
            # Append to redirect chain
            redirect_chain="$redirect_chain\n$status_code $current_url -> $next_url"
            
            # Update current URL for next iteration
            current_url="$next_url"
        else
            # Not a redirect, this is the final destination
            redirect_chain="$redirect_chain\n$status_code $current_url (final)"
            break
        fi
    done
    
    # Clean up
    rm -f "$temp_file"
    
    # Return redirect chain
    echo -e "$redirect_chain"
}

# Output summary header
echo "=== Redirect Rules Checker ==="
echo "Checking redirect rules..."
echo ""

# Initialize counters
TOTAL=0
PASSED=0
FAILED=0

# Process each rule
while IFS= read -r line; do
    # Skip empty lines
    [[ -z "$line" ]] && continue
    
    # Parse the CSV line
    IFS=',' read -r code domain path redirect_to <<< "$line"
    
    # Remove any leading/trailing whitespace
    code=$(echo "$code" | xargs)
    domain=$(echo "$domain" | xargs)
    path=$(echo "$path" | xargs)
    redirect_to=$(echo "$redirect_to" | xargs)
    
    # Skip if any required field is missing
    if [[ -z "$code" || -z "$domain" || -z "$path" || -z "$redirect_to" ]]; then
        echo "Warning: Invalid rule format - $line"
        continue
    fi
    
    # Convert regex path to an actual URL path
    # Remove regex symbols to create a valid path for testing
    test_path=$(echo "$path" | sed 's/\^//g; s/\\//g; s/\$//g; s/?//g')
    
    # Construct the URL to test
    test_url="https://$domain$test_path"
    
    # Increment total count
    ((TOTAL++))
    
    echo "Rule #$TOTAL: $code,\"$domain\",\"$path\",\"$redirect_to\""
    echo "Testing URL: $test_url"
    echo "Expected: $code redirect to $redirect_to"
    echo ""
    echo "Redirect trail:"
    
    # Get the redirect chain
    redirect_chain=$(follow_redirects "$test_url")
    echo -e "$redirect_chain"
    
    # Check if the redirect chain ends with the expected URL
    final_url=$(echo -e "$redirect_chain" | grep "(final)" | awk '{print $2}')
    final_status=$(echo -e "$redirect_chain" | grep "(final)" | awk '{print $1}')
    
    # Normalize URLs for comparison
    normalized_final_url=$(normalize_url "$final_url")
    normalized_redirect_to=$(normalize_url "$redirect_to")
    
    # Determine if there was a redirect to the expected URL
    contains_expected=$(echo -e "$redirect_chain" | grep -c " -> $redirect_to")
    redirects_ok=false
    
    # Check if a redirect with the expected status code was found
    if [[ $(echo -e "$redirect_chain" | grep -c "^$code .* -> $redirect_to") -gt 0 ]]; then
        redirects_ok=true
    fi
    
    # Check if final status is 200
    final_status_ok=false
    if [[ "$final_status" == "200" ]]; then
        final_status_ok=true
    fi
    
    # Check if final URL matches expected redirect_to URL
    final_url_ok=false
    if [[ "$normalized_final_url" == "$normalized_redirect_to" ]]; then
        final_url_ok=true
    fi
    
    # Determine overall success
    if $redirects_ok && $final_status_ok && $final_url_ok; then
        status="✅ PASS"
        ((PASSED++))
    else
        status="❌ FAIL"
        ((FAILED++))
        
        # Show specific failure reasons
        if ! $redirects_ok; then
            echo "Failure: Expected $code redirect to $redirect_to not found"
        fi
        
        if ! $final_status_ok; then
            echo "Failure: Final status code is $final_status, expected 200"
        fi
        
        if ! $final_url_ok; then
            echo "Failure: Final URL is $final_url, expected $redirect_to"
        fi
    fi
    
    echo ""
    echo "Status: $status"
    echo "--------------------------------------------------------------------------------"
    echo ""
    
done <<< "$RULES"

# Output summary
echo ""
echo "=== Summary ==="
echo "Total rules checked: $TOTAL"
echo "Passed: $PASSED"
echo "Failed: $FAILED"
if [[ $TOTAL -gt 0 ]]; then
    echo "Success rate: $(( PASSED * 100 / TOTAL ))%"
fi
