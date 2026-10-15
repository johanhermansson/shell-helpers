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
    echo "turned into a concrete URL to request. With perl installed, that URL is"
    echo "checked against the pattern and \$1..\$9 are taken from the match."
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
# Echoes "<index after the quantifier> <count>". The count is the minimum of
# {n}, {n,} and {n,m}, "many" for + and *, and 1 for ? or no quantifier at
# all - an optional element is simply included once.
read_quantifier() {
    local pattern="$1"
    local idx="$2"
    local count=1
    local spec="" j
    case "${pattern:idx:1}" in
        '*'|'+')
            count="many"
            (( idx++ ))
            ;;
        '?')
            (( idx++ ))
            ;;
        '{')
            j=$(( idx + 1 ))
            while [[ -n "${pattern:j:1}" && "${pattern:j:1}" != '}' ]]; do
                spec+="${pattern:j:1}"
                (( j++ ))
            done
            spec="${spec%%,*}"
            # Anything but {n...} is a literal brace, not a quantifier
            if [[ "$spec" =~ ^[0-9]+$ ]]; then
                count=$(( 10#$spec ))
                idx=$(( j + 1 ))
            fi
            ;;
    esac
    # Lazy and possessive modifiers (*?, ++) make no difference to a sample
    while [[ "${pattern:idx:1}" == [*+?] ]]; do (( idx++ )); done
    echo "$idx $count"
}

# Function to build a sample of the length a quantifier asks for from a pool
# of characters. The pool is cycled, so \d{4} becomes 1234 and [a-z]{8}
# becomes samplesa. "many" gives the word pools in full and three characters
# of anything else.
sample_repeat() {
    local pool="$1"
    local count="$2"
    local out="" k

    # A space is a single URL encoded unit and is never cut up
    if [[ "$pool" == "%20" ]]; then
        [[ "$count" == "many" ]] && count=1
        for (( k = 0; k < count; k++ )); do out+="%20"; done
        printf '%s' "$out"
        return
    fi

    if [[ "$count" == "many" ]]; then
        case "$pool" in
            sample|SAMPLE) count=6 ;;
            *) count=3 ;;
        esac
    fi
    for (( k = 0; k < count; k++ )); do
        out+="${pool:k % ${#pool}:1}"
    done
    printf '%s' "$out"
}

# Function to find the index of the ] that closes the class starting at $2
class_end() {
    local pattern="$1"
    local j=$(( $2 + 1 ))
    local n=${#pattern}
    [[ "${pattern:j:1}" == '^' ]] && (( j++ ))
    [[ "${pattern:j:1}" == ']' ]] && (( j++ ))
    while (( j < n )) && [[ "${pattern:j:1}" != ']' ]]; do
        if [[ "${pattern:j:2}" == '[:' ]]; then
            # A POSIX class such as [:digit:] has a ] of its own
            (( j += 2 ))
            while (( j < n )) && [[ "${pattern:j:2}" != ':]' ]]; do (( j++ )); done
            (( j += 2 ))
            continue
        fi
        [[ "${pattern:j:1}" == '\' ]] && (( j++ ))
        (( j++ ))
    done
    echo "$j"
}

# Function to pick a sample pool for a character class such as [a-z0-9-].
# Candidates are tried against the class with bash's own regex engine, after
# translating the Perl style escapes it does not understand.
class_pool() {
    local cls="$1"
    local body="${cls:1:${#cls}-2}"
    local negated="" translated="" close="" dash="" caret=""
    local k c re candidate

    if [[ "$body" == ^* ]]; then
        negated="^"
        body="${body:1}"
    fi

    # Translate escapes into what a POSIX bracket expression expects
    for (( k = 0; k < ${#body}; k++ )); do
        c="${body:k:1}"
        if [[ "$c" != '\' ]]; then
            translated+="$c"
            continue
        fi
        (( k++ ))
        c="${body:k:1}"
        case "$c" in
            d) translated+="0-9" ;;
            w) translated+="A-Za-z0-9_" ;;
            s) translated+="[:space:]" ;;
            ']') close="]" ;;
            '-') dash="-" ;;
            '^') caret="^" ;;
            *) translated+="$c" ;;
        esac
    done
    re="[${negated}${close}${translated}${caret}${dash}]"

    for candidate in sample 1234567890 SAMPLE 123; do
        if [[ "$candidate" =~ ^${re}+$ ]]; then
            echo "$candidate"
            return
        fi
    done
    for (( k = 0; k < 66; k++ )); do
        candidate="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~"
        candidate="${candidate:k:1}"
        if [[ "$candidate" =~ ^${re}$ ]]; then
            echo "$candidate"
            return
        fi
    done
    echo "x"
}

# Function to turn a regex, or a part of one, into a concrete string that it
# matches. Sets RENDERED. Capturing groups are stored in CAPTURES in the order
# of their opening parenthesis, so nested groups are numbered the way the
# regex engine numbers them. SAW_WILDCARD is set when part of the pattern
# stands for arbitrary text rather than something fixed.
# With $2 set to true the pattern is a whole path, which starts with a slash.
render_regex() {
    local pattern="$1"
    local top="${2:-false}"
    local out=""
    local i=0 n=${#pattern}
    local ch c next_ch after count depth j k inner pool sample last
    local capturing slot outer_wild group_wild

    while (( i < n )); do
        ch="${pattern:i:1}"
        sample=""
        case "$ch" in
            '\')
                next_ch="${pattern:i+1:1}"
                case "$next_ch" in
                    b|B|A|z|Z|G)
                        # Anchors and word boundaries match no text
                        (( i += 2 ))
                        continue
                        ;;
                    d) pool="1234567890" ;;
                    D|w|S) pool="sample" ;;
                    W) pool="-" ;;
                    s) pool="%20" ;;
                    *) pool="" ;;
                esac
                if [[ -z "$pool" ]]; then
                    # Any other escaped character is taken literally
                    out+="$next_ch"
                    (( i += 2 ))
                    continue
                fi
                [[ "$pool" == "sample" ]] && SAW_WILDCARD=true
                read -r after count <<< "$(read_quantifier "$pattern" $(( i + 2 )))"
                sample=$(sample_repeat "$pool" "$count")
                i=$after
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
                    if [[ "$c" == '[' ]]; then
                        # A class may hold parentheses of its own
                        k=$(class_end "$pattern" "$j")
                        inner+="${pattern:j:k-j+1}"
                        j=$(( k + 1 ))
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

                read -r after count <<< "$(read_quantifier "$pattern" $(( j + 1 )))"

                capturing=true
                case "$inner" in
                    '?:'*)
                        inner="${inner:2}"
                        capturing=false
                        ;;
                    '?='*|'?!'*|'?<='*|'?<!'*)
                        # Lookarounds match no text
                        inner=""
                        capturing=false
                        ;;
                    '?<'*|'?P<'*)
                        # Named group
                        inner="${inner#*>}"
                        ;;
                    '?'[a-zA-Z-]*':'*)
                        # Scoped flags such as (?i:...)
                        inner="${inner#*:}"
                        capturing=false
                        ;;
                esac

                if $capturing; then
                    slot=${#CAPTURES[@]}
                    CAPTURES+=("")
                fi

                outer_wild=$SAW_WILDCARD
                SAW_WILDCARD=false
                render_regex "$inner"
                group_wild=$SAW_WILDCARD
                $outer_wild && SAW_WILDCARD=true

                # A group that stands for arbitrary text, rather than a choice
                # between fixed alternatives, is worth knowing about later
                $capturing && $group_wild && CAPTURE_WILDCARD=true

                # A group at the very start of a path stands for the whole
                # path, leading slash included
                if $top && [[ -z "$out" && -n "$RENDERED" && "$RENDERED" != /* ]]; then
                    RENDERED="/$RENDERED"
                fi

                # One repetition of the group is enough, and it is also what
                # the engine captures; {n} repeats it
                [[ "$count" == "many" ]] && count=1
                for (( k = 0; k < count; k++ )); do sample+="$RENDERED"; done
                (( count > 0 )) && $capturing && CAPTURES[slot]="$RENDERED"
                i=$after
                ;;
            '[')
                j=$(class_end "$pattern" "$i")
                pool=$(class_pool "${pattern:i:j-i+1}")
                [[ "$pool" == sample || "$pool" == SAMPLE ]] && SAW_WILDCARD=true
                read -r after count <<< "$(read_quantifier "$pattern" $(( j + 1 )))"
                sample=$(sample_repeat "$pool" "$count")
                i=$after
                ;;
            '.')
                read -r after count <<< "$(read_quantifier "$pattern" $(( i + 1 )))"
                if [[ "$count" == "1" ]]; then
                    # A single dot is most often a literal dot that was not
                    # escaped, and a dot is a character it matches
                    sample="."
                else
                    [[ "$count" == "many" ]] && SAW_WILDCARD=true
                    sample=$(sample_repeat "sample" "$count")
                fi
                i=$after
                ;;
            '{')
                read -r after count <<< "$(read_quantifier "$pattern" "$i")"
                if (( after == i )); then
                    # Not a quantifier, just a brace
                    out+="{"
                    (( i++ ))
                    continue
                fi
                # Quantifier on the literal we already emitted
                last="${out: -1}"
                out="${out%?}"
                [[ "$count" == "many" ]] && count=1
                for (( k = 0; k < count; k++ )); do out+="$last"; done
                i=$after
                continue
                ;;
            '*'|'+'|'?')
                # Quantifier on the literal we already emitted: keep it once
                (( i++ ))
                continue
                ;;
            '^'|'$'|')')
                (( i++ ))
                continue
                ;;
            '|')
                # Alternation: the first branch is enough to exercise the rule
                break
                ;;
            *)
                out+="$ch"
                (( i++ ))
                continue
                ;;
        esac

        if $top && [[ -z "$out" && -n "$sample" && "$sample" != /* ]]; then
            sample="/$sample"
        fi
        out+="$sample"
    done

    RENDERED="$out"
}

# Function to check the derived path against the original regex with perl,
# whose regex syntax is the one redirect engines use. When it matches, the
# captures are taken from perl, so $1..$9 are exactly what the engine sees.
# Sets PATH_CHECK to matched, mismatch or unchecked (no perl, or a pattern
# perl cannot compile).
verify_test_path() {
    local pattern="$1"
    local candidate result status count line k

    PATH_CHECK="unchecked"
    command -v perl > /dev/null 2>&1 || return

    # Engines differ on whether the path they match starts with a slash
    for candidate in "$TEST_PATH" "${TEST_PATH#/}"; do
        result=$(perl -e '
            my ($re, $path) = @ARGV;
            my $compiled = eval { qr/$re/ };
            exit 2 unless $compiled;
            exit 1 unless $path =~ $compiled;
            print $#+, "\n";
            for my $i (1 .. $#+) {
                print defined $-[$i] ? substr($path, $-[$i], $+[$i] - $-[$i]) : "", "\n";
            }
        ' "$pattern" "$candidate" 2> /dev/null)
        status=$?
        if (( status == 0 )); then
            PATH_CHECK="matched"
            CAPTURES=()
            {
                read -r count
                for (( k = 0; k < count; k++ )); do
                    IFS= read -r line
                    CAPTURES+=("$line")
                done
            } <<< "$result"
            return
        fi
        (( status == 2 )) && return
    done
    PATH_CHECK="mismatch"
}

# Function to turn a regex path pattern into a concrete path to request.
# Sets TEST_PATH, CAPTURES (CAPTURES[0] is $1, CAPTURES[1] is $2, ...),
# CAPTURE_WILDCARD and PATH_CHECK
build_test_path() {
    local pattern="$1"
    local flagless="$pattern"
    CAPTURES=()
    CAPTURE_WILDCARD=false
    SAW_WILDCARD=false

    # Inline flag groups such as (?i) (?im) (?-i) match no text
    while [[ "$flagless" =~ \(\?[a-zA-Z-]+\) ]]; do
        flagless="${flagless/"${BASH_REMATCH[0]}"/}"
    done

    render_regex "$flagless" true
    TEST_PATH="$RENDERED"
    [[ "$TEST_PATH" != /* ]] && TEST_PATH="/$TEST_PATH"

    verify_test_path "$pattern"
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
if $DRY_RUN; then
    echo "Dry run: deriving test URLs and expected targets, no requests are made"
else
    echo "Checking redirect rules..."
fi
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

    rule_warned=false

    # A test URL the pattern does not match says nothing about the rule
    if [[ "$PATH_CHECK" == "mismatch" ]]; then
        echo "⚠️  Warning: the path pattern does not match $TEST_PATH - the pattern uses"
        echo "   syntax that could not be turned into a URL, so this check is not reliable"
        rule_warned=true
    fi

    # An unresolved $1 means the target references a group the path does not have
    if [[ "$expected_url" =~ (\$|\\)[1-9] ]]; then
        echo "⚠️  Warning: the target references a capture group the path does not have"
        rule_warned=true
    fi

    # The reverse: the path captures something the target never uses. Usually a
    # $1 that the shell expanded away before the script saw the rule.
    if $CAPTURE_WILDCARD && [[ "$redirect_to" != *'$'* && "$redirect_to" != *'\'[1-9]* ]]; then
        echo "⚠️  Warning: the path captures a group but the target does not use it"
        rule_warned=true
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
        $rule_warned && ((WARNED++))
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
if $DRY_RUN; then
    echo "Rules parsed: $TOTAL"
    echo "Rules with warnings: $WARNED"
    echo "Dry run: no requests were made, so no rule has passed or failed"
    exit 0
fi
echo "Total rules checked: $TOTAL"
echo "Passed: $PASSED"
if (( WARNED > 0 )); then
    echo "Passed with warnings: $WARNED"
fi
echo "Failed: $FAILED"
if [[ $TOTAL -gt 0 ]]; then
    echo "Success rate: $(( PASSED * 100 / TOTAL ))%"
fi
