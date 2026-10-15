#!/bin/bash

# Redirect Rules Checker
# This script checks if redirect rules defined in CSV format are correctly implemented
# Format: code,domain,path,redirect_to
#
# The path field is a regular expression as used by the redirect engine, e.g.
#   (?i)^/old-page\.aspx$        case-insensitive inline flag
#   ^/products/(.*)$             capture groups
#   ^.*                          catch-all
# The redirect_to field is either an absolute URL, a protocol relative URL or a
# path on the same domain (/new-page/), and may reference capture groups from
# the path with $1..$9 (or \1..\9).

# Default values
RULES_FILE=""
RULES_SOURCE="file"
VERBOSE=false
DRY_RUN=false
TIMEOUT=10
MAX_HOPS=10

# Function to display usage information
usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -f, --file FILE       Read redirect rules from FILE (CSV format)"
    echo "  -r, --rules RULES     Specify redirect rules as a string (CSV format)"
    echo "  -v, --verbose         Show detailed information for each check"
    echo "  -n, --dry-run         Only show the derived test URL and expected target"
    echo "  -t, --timeout SEC     Set curl timeout in seconds (default: 10)"
    echo "  -h, --help            Display this help message"
    echo ""
    echo "CSV Format: code,domain,path,redirect_to"
    echo ""
    echo "The path is a regex; inline flags ((?i)), escapes (\\.), quantifiers,"
    echo "character classes, alternation and capture groups are all understood and"
    echo "turned into a concrete URL to request."
    echo ""
    echo "The target is an absolute URL, a protocol relative URL (//host/path) or a"
    echo "path on the same domain (/new-page/), and may use \$1..\$9 to reference"
    echo "capture groups from the path."
    echo ""
    echo "Rules given with -r must be single quoted, otherwise the shell expands"
    echo "\$1 away before the script sees it."
    echo ""
    echo "Examples:"
    echo "  301,www.example.com,^/old-page/?$,https://www.example.com/new-page/"
    echo "  301,www.example.com,(?i)^/old-page\\.aspx$,/new-page/"
    echo "  301,example.com,(.*),https://www.example.com\$1"
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
            RULES_SOURCE="argument"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -n|--dry-run)
            DRY_RUN=true
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

# Function to strip a wrapping pair of double quotes from a CSV field
unquote_field() {
    local value="$1"
    if [[ "$value" == \"*\" ]]; then
        value="${value:1:${#value}-2}"
        # Un-escape doubled quotes used by CSV
        value="${value//\"\"/\"}"
    fi
    echo "$value"
}

# Function to read a quantifier at index $2 of pattern $1.
# Echoes "<index after the quantifier> <repeat count>"
read_quantifier() {
    local pattern="$1"
    local idx="$2"
    local rep=1
    local count="" j
    case "${pattern:idx:1}" in
        '*'|'+'|'?')
            (( idx++ ))
            ;;
        '{')
            j=$(( idx + 1 ))
            while [[ -n "${pattern:j:1}" && "${pattern:j:1}" != '}' ]]; do
                count+="${pattern:j:1}"
                (( j++ ))
            done
            idx=$(( j + 1 ))
            count="${count%%,*}"
            [[ "$count" =~ ^[0-9]+$ ]] && rep=$count
            ;;
    esac
    # Collapse any remaining quantifier characters
    while [[ "${pattern:idx:1}" == [*+?] ]]; do (( idx++ )); done
    echo "$idx $rep"
}

# Function to repeat a sampled value to satisfy a {n} quantifier
sample_repeat() {
    local sample="$1"
    local rep="$2"
    local out="" k
    if (( rep <= 1 )); then
        printf '%s' "$sample"
        return
    fi
    if [[ "$sample" == "123" ]]; then
        for (( k = 1; k <= rep; k++ )); do out+=$(( k % 10 )); done
    else
        for (( k = 1; k <= rep; k++ )); do out+="${sample:0:1}"; done
    fi
    printf '%s' "$out"
}

# Function to pick a concrete value for a regex sub-pattern (group or class)
sample_for() {
    local inner="$1"

    # Alternation: the first branch is enough to exercise the rule
    if [[ "$inner" == *"|"* ]]; then
        printf '%s' "${inner%%|*}" | sed 's/\\\(.\)/\1/g; s/[()]//g'
        return
    fi

    case "$inner" in
        '\d'*|'[0-9]'*|'[[:digit:]]'*)
            printf '123'
            ;;
        '.'*|'\w'*|'[^'*|'[a-'*|'[A-'*|'[[:'*)
            printf 'sample'
            ;;
        *)
            # A literal group such as (foo): use it as-is, without regex noise
            printf '%s' "$inner" | sed 's/\\\(.\)/\1/g; s/[*+?()]//g'
            ;;
    esac
}

# Function to turn a regex path pattern into a concrete path to request.
# Sets TEST_PATH and CAPTURES (CAPTURES[0] is $1, CAPTURES[1] is $2, ...)
build_test_path() {
    local pattern="$1"
    local out=""
    local i=0 n ch after rep depth j inner cls sample capturing next_ch
    CAPTURES=()
    CAPTURE_WILDCARD=false

    # Drop inline flag groups anywhere in the pattern, e.g. (?i) (?im) (?-i)
    while [[ "$pattern" =~ \(\?[a-zA-Z-]+\) ]]; do
        pattern="${pattern/"${BASH_REMATCH[0]}"/}"
    done

    # Drop the anchors
    pattern="${pattern#^}"
    pattern="${pattern%\$}"

    n=${#pattern}
    while (( i < n )); do
        ch="${pattern:i:1}"
        case "$ch" in
            '\')
                # Escaped character: a shorthand class gets a sample,
                # anything else is taken literally
                next_ch="${pattern:i+1:1}"
                case "$next_ch" in
                    d|D) sample="123" ;;
                    w|W) sample="sample" ;;
                    s) sample="%20" ;;
                    *) sample="" ;;
                esac
                if [[ -n "$sample" ]]; then
                    read -r after rep <<< "$(read_quantifier "$pattern" $(( i + 2 )))"
                    sample=$(sample_repeat "$sample" "$rep")
                    if [[ -z "$out" && "$sample" != /* ]]; then
                        sample="/$sample"
                    fi
                    out+="$sample"
                    i=$after
                else
                    out+="$next_ch"
                    (( i += 2 ))
                fi
                ;;
            '(')
                # Find the matching closing parenthesis
                depth=1
                j=$(( i + 1 ))
                inner=""
                while (( j < n )); do
                    c="${pattern:j:1}"
                    if [[ "$c" == '\' ]]; then
                        inner+="${pattern:j:2}"
                        (( j += 2 ))
                        continue
                    fi
                    if [[ "$c" == '(' ]]; then
                        (( depth++ ))
                    elif [[ "$c" == ')' ]]; then
                        (( depth-- ))
                        (( depth == 0 )) && break
                    fi
                    inner+="$c"
                    (( j++ ))
                done

                # Skip any quantifier attached to the group
                read -r after rep <<< "$(read_quantifier "$pattern" $(( j + 1 )))"

                capturing=true
                if [[ "$inner" == '?:'* ]]; then
                    inner="${inner#\?:}"
                    capturing=false
                fi

                sample=$(sample_for "$inner")
                # A group that stands for arbitrary path, rather than a choice
                # between fixed alternatives, is worth knowing about later
                if $capturing && [[ "$sample" == "sample" ]]; then
                    CAPTURE_WILDCARD=true
                fi
                # A wildcard group at the very start stands for the whole path,
                # leading slash included
                if [[ -z "$out" && -n "$sample" && "$sample" != /* ]]; then
                    sample="/$sample"
                fi
                $capturing && CAPTURES+=("$sample")
                out+="$sample"
                i=$after
                ;;
            '[')
                # Character class
                j=$(( i + 1 ))
                [[ "${pattern:j:1}" == '^' ]] && (( j++ ))
                [[ "${pattern:j:1}" == ']' ]] && (( j++ ))
                while (( j < n )) && [[ "${pattern:j:1}" != ']' ]]; do
                    [[ "${pattern:j:1}" == '\' ]] && (( j++ ))
                    (( j++ ))
                done
                cls="${pattern:i:j-i+1}"
                read -r after rep <<< "$(read_quantifier "$pattern" $(( j + 1 )))"
                sample=$(sample_repeat "$(sample_for "$cls")" "$rep")
                if [[ -z "$out" && -n "$sample" && "$sample" != /* ]]; then
                    sample="/$sample"
                fi
                out+="$sample"
                i=$after
                ;;
            '.')
                case "${pattern:i+1:1}" in
                    '*'|'+') sample="sample" ;;
                    '?') sample="" ;;
                    *) sample="x" ;;
                esac
                read -r after rep <<< "$(read_quantifier "$pattern" $(( i + 1 )))"
                [[ "$sample" == "x" ]] && sample=$(sample_repeat "$sample" "$rep")
                if [[ -z "$out" && -n "$sample" && "$sample" != /* ]]; then
                    sample="/$sample"
                fi
                out+="$sample"
                i=$after
                ;;
            '{')
                # Quantifier on the previous literal: keep the single literal
                j=$i
                while (( j < n )) && [[ "${pattern:j:1}" != '}' ]]; do (( j++ )); done
                i=$(( j + 1 ))
                ;;
            '*'|'+'|'?')
                # Quantifier on the literal we already emitted
                (( i++ ))
                ;;
            '|')
                # Top level alternation: the first branch is enough
                break
                ;;
            *)
                out+="$ch"
                (( i++ ))
                ;;
        esac
    done

    [[ "$out" != /* ]] && out="/$out"
    TEST_PATH="$out"
}

# Function to expand the target of a rule into an absolute URL.
# Substitutes $1..$9 / \1..\9 with the captures from the path pattern.
build_expected_url() {
    local target="$1"
    local domain="$2"
    local index value

    # Capture group references
    for (( index = ${#CAPTURES[@]}; index >= 1; index-- )); do
        value="${CAPTURES[index-1]}"
        target="${target//\$\{$index\}/$value}"
        target="${target//\$$index/$value}"
        target="${target//\\$index/$value}"
    done

    case "$target" in
        http://*|https://*)
            ;;
        //*)
            # Protocol relative target
            target="https:$target"
            ;;
        /*)
            # Path only target: same domain
            target="https://$domain$target"
            ;;
        *)
            # Bare host or relative path on the same domain
            if [[ "$target" == *.*/* || "$target" == *.* && "$target" != */* ]]; then
                target="https://$target"
            else
                target="https://$domain/$target"
            fi
            ;;
    esac

    echo "$target"
}

# Function to reduce a URL to its scheme and host
url_origin() {
    local url="$1"
    local host="${url#*://}"
    echo "${url%%://*}://${host%%/*}"
}

# Function to resolve a Location header against the URL it was returned for
resolve_location() {
    local base="$1"
    local location="$2"
    local scheme host base_path

    scheme="${base%%://*}"
    host="${base#*://}"
    host="${host%%/*}"

    case "$location" in
        http://*|https://*)
            echo "$location"
            ;;
        //*)
            echo "$scheme:$location"
            ;;
        /*)
            echo "$scheme://$host$location"
            ;;
        *)
            base_path="${base#*://}"
            base_path="${base_path#*/}"
            if [[ "$base_path" == "${base#*://}" ]]; then
                base_path=""
            fi
            base_path="/${base_path}"
            base_path="${base_path%/*}/"
            echo "$scheme://$host${base_path}$location"
            ;;
    esac
}

# Function to follow redirects and capture the redirect chain
follow_redirects() {
    local url="$1"
    local temp_file=$(mktemp)
    local redirect_chain=""
    local current_url="$url"
    local next_url=""
    local status_code=""
    local hops=0

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

            # A relative Location is resolved against the URL that returned it
            next_url=$(resolve_location "$current_url" "$next_url")

            # Append to redirect chain
            redirect_chain="$redirect_chain\n$status_code $current_url -> $next_url"

            # Stop on redirect loops instead of following them forever
            (( hops++ ))
            if (( hops >= MAX_HOPS )); then
                redirect_chain="$redirect_chain\nError: Stopped after $MAX_HOPS redirects (possible loop)"
                break
            fi

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
WARNED=0
FAILED=0

# Process each rule
while IFS= read -r line; do
    # Strip a trailing carriage return from CRLF files
    line="${line%$'\r'}"

    # Skip empty lines and comments
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" == \#* ]] && continue

    # Parse the CSV line. The path is a regex and may itself contain commas,
    # so the first two and the last field are taken and the rest is the path.
    code="${line%%,*}"
    rest="${line#*,}"
    domain="${rest%%,*}"
    rest="${rest#*,}"
    redirect_to="${rest##*,}"
    path="${rest%,*}"

    # Remove any leading/trailing whitespace and CSV quoting
    code=$(unquote_field "$(echo "$code" | xargs)")
    domain=$(unquote_field "$(echo "$domain" | xargs)")
    path=$(unquote_field "$path")
    path="${path#"${path%%[![:space:]]*}"}"
    path="${path%"${path##*[![:space:]]}"}"
    redirect_to=$(unquote_field "$(echo "$redirect_to" | xargs)")

    # Skip the header row of an exported CSV
    code_lower=$(echo "$code" | tr '[:upper:]' '[:lower:]')
    if [[ "$code_lower" == "code" || "$code_lower" == "status" ]]; then
        continue
    fi

    # Skip if any required field is missing
    if [[ -z "$code" || -z "$domain" || -z "$path" || -z "$redirect_to" || "$path" == "$rest" ]]; then
        echo "Warning: Invalid rule format - $line"
        continue
    fi

    # Convert the regex path into a concrete path, then build the URL to test
    build_test_path "$path"
    test_url="https://$domain$TEST_PATH"

    # Resolve the expected target (capture groups, same domain paths)
    expected_url=$(build_expected_url "$redirect_to" "$domain")

    # Increment total count
    ((TOTAL++))

    echo "Rule #$TOTAL: $code,\"$domain\",\"$path\",\"$redirect_to\""
    echo "Testing URL: $test_url"
    echo "Expected: $code redirect to $expected_url"

    # An unresolved $1 means the target references a group the path does not have
    if [[ "$expected_url" =~ (\$|\\)[1-9] ]]; then
        echo "⚠️  Warning: the target references a capture group the path does not have"
    fi

    # The reverse: the path captures something the target never uses. Usually a
    # $1 that the shell expanded away before the script saw the rule.
    if $CAPTURE_WILDCARD && [[ "$redirect_to" != *'$'* && "$redirect_to" != *'\'[1-9]* ]]; then
        echo "⚠️  Warning: the path captures a group but the target does not use it"
        if [[ "$RULES_SOURCE" == "argument" ]]; then
            echo "   A \$1 inside double quotes is expanded by the shell - pass the rule"
            echo "   in single quotes: -r '$code,$domain,$path,$redirect_to\$1'"
        fi
    fi

    if $VERBOSE && [[ ${#CAPTURES[@]} -gt 0 ]]; then
        for (( c = 1; c <= ${#CAPTURES[@]}; c++ )); do
            echo "  \$$c = ${CAPTURES[c-1]}"
        done
    fi

    if $DRY_RUN; then
        echo "--------------------------------------------------------------------------------"
        echo ""
        continue
    fi

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
    normalized_expected=$(normalize_url "$expected_url")

    # Walk the chain and look for the redirect this rule describes. Compared as
    # strings, so regex characters in URLs cannot mislead the match. A hop that
    # is close but not equal is remembered, to explain a failure.
    redirects_ok=false
    hop_count=0
    match_index=0
    near_miss=""
    wrong_status=""
    while IFS= read -r hop; do
        [[ "$hop" != *" -> "* ]] && continue
        (( hop_count++ ))
        hop_status="${hop%% *}"
        hop_target="${hop##* -> }"
        if [[ "$(normalize_url "$hop_target")" == "$normalized_expected" ]]; then
            if [[ "$hop_status" == "$code" ]]; then
                if ! $redirects_ok; then
                    redirects_ok=true
                    match_index=$hop_count
                fi
            elif [[ -z "$wrong_status" ]]; then
                wrong_status="$hop_status"
            fi
        elif [[ -z "$near_miss" && "$hop_status" == "$code" ]] \
            && [[ "$(url_origin "$hop_target")" == "$(url_origin "$expected_url")" ]]; then
            near_miss="$hop_target"
        fi
    done <<< "$(echo -e "$redirect_chain")"

    # Check if final status is 200
    final_status_ok=false
    if [[ "$final_status" == "200" ]]; then
        final_status_ok=true
    fi

    # Collect what is worth pointing out even when the rule itself is right:
    # hops before the rule fired, and hops after it.
    WARNINGS=()
    if (( hop_count > 1 )); then
        if $redirects_ok; then
            WARNINGS+=("$hop_count redirects in the chain, the rule fired on redirect $match_index")
        else
            WARNINGS+=("$hop_count redirects in the chain")
        fi
    fi
    if [[ "$normalized_final_url" != "$normalized_expected" ]]; then
        WARNINGS+=("the visitor lands on $final_url, not on the rule's target $expected_url")
    fi

    for (( w = 0; w < ${#WARNINGS[@]}; w++ )); do
        echo "⚠️  Warning: ${WARNINGS[w]}"
    done

    # Determine overall success. The rule is implemented when the redirect it
    # describes happened and the chain ends on a 200 - where the chain goes
    # after that is another rule's business, so it only warrants a warning.
    if $redirects_ok && $final_status_ok; then
        if [[ ${#WARNINGS[@]} -gt 0 ]]; then
            status="⚠️  PASS"
            ((WARNED++))
        else
            status="✅ PASS"
        fi
        ((PASSED++))
    else
        status="❌ FAIL"
        ((FAILED++))

        # Show specific failure reasons
        if ! $redirects_ok; then
            echo "Failure: Expected $code redirect to $expected_url not found"
            if [[ -n "$wrong_status" ]]; then
                echo "         A $wrong_status redirect to that URL was found instead"
            elif [[ -n "$near_miss" ]]; then
                echo "         A $code redirect to $near_miss was found instead (same host, different path)"
                if $CAPTURE_WILDCARD && [[ "$redirect_to" != *'$'* ]]; then
                    echo "         Hint: the target needs the captured path: ${redirect_to}\$1"
                    if [[ "$RULES_SOURCE" == "argument" ]]; then
                        echo "         If you did write \$1, the shell expanded it - use single quotes"
                    fi
                fi
            fi
        fi

        if ! $final_status_ok; then
            echo "Failure: Final status code is $final_status, expected 200"
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
if (( WARNED > 0 )); then
    echo "Passed with warnings: $WARNED"
fi
echo "Failed: $FAILED"
if [[ $TOTAL -gt 0 ]]; then
    echo "Success rate: $(( PASSED * 100 / TOTAL ))%"
fi
