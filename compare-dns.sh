#!/bin/bash

# Function to display usage
usage() {
    echo "Usage: $0 --domain <domain> --ns1 <nameserver1> --ns2 <nameserver2> [--subdomains <subdomain1,subdomain2,...>]"
    exit 1
}

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --domain) DOMAIN="$2"; shift ;;
        --ns1) NS_ONE="$2"; shift ;;
        --ns2) NS_LOOPIA="$2"; shift ;;
        --subdomains) SUBDOMAINS="$2"; shift ;;
        *) usage ;;
    esac
    shift
done

# Check if required parameters are provided
if [[ -z "$DOMAIN" || -z "$NS_ONE" || -z "$NS_LOOPIA" ]]; then
    usage
fi

# Function to fetch and sort records
fetch_and_sort_records() {
    local ns="$1"
    local domain="$2"
    local record="$3"

    if [[ "$record" == "TXT" || "$record" == "MX" ]]; then
        # Fetch multiple records and sort them
        dig @$ns "$domain" "$record" +short | sort
    else
        # Fetch single record
        dig @$ns "$domain" "$record" +short
    fi
}

# Print table header
printf "%-10s | %-30s | %-30s | %-10s\n" "RECORD" "Domain/Subdomain" "ns1" "ns2" "Compares?"
printf "%-10s | %-30s | %-30s | %-10s\n" "--------" "------------------------------" "------------------------------" "----------"

# Create a simple comparison script for DNS records for the main domain
for record in A AAAA MX TXT CNAME NS SRV; do
    # Check main domain
    VALUE_ONE=$(fetch_and_sort_records "$NS_ONE" "$DOMAIN" "$record")
    VALUE_LOOPIA=$(fetch_and_sort_records "$NS_LOOPIA" "$DOMAIN" "$record")

    # Split values into arrays for multi-line handling
    IFS=$'\n' read -r -d '' -a values_one <<< "$VALUE_ONE"
    IFS=$'\n' read -r -d '' -a values_loopia <<< "$VALUE_LOOPIA"

    # Determine the maximum length for comparison
    max_length=${#values_one[@]}
    if [[ ${#values_loopia[@]} -gt $max_length ]]; then
        max_length=${#values_loopia[@]}
    fi

    # Compare values index by index for the main domain
    for ((i=0; i<max_length; i++)); do
        value_ns1="${values_one[i]:-N/A}"  # Default to N/A if not set
        value_ns2="${values_loopia[i]:-N/A}"  # Default to N/A if not set

        # Determine comparison status
        if [[ "$value_ns1" == "$value_ns2" ]]; then
            COMPARES="yes"
        else
            COMPARES="no"
        fi

        # Print the result for the main domain
        printf "%-10s | %-30s | %-30s | %-30s | %-10s\n" "$record" "@" "$value_ns1" "$value_ns2" "$COMPARES"
    done
done

# Check subdomains if provided
if [[ -n "$SUBDOMAINS" ]]; then
    IFS=',' read -r -a subdomain_array <<< "$SUBDOMAINS"
    
    for subdomain in "${subdomain_array[@]}"; do
        for record in A AAAA MX TXT CNAME NS SRV; do
            # Check each record type for the subdomain
            VALUE_ONE=$(fetch_and_sort_records "$NS_ONE" "$subdomain.$DOMAIN" "$record")
            VALUE_LOOPIA=$(fetch_and_sort_records "$NS_LOOPIA" "$subdomain.$DOMAIN" "$record")

            # Split values into arrays for multi-line handling
            IFS=$'\n' read -r -d '' -a values_one <<< "$VALUE_ONE"
            IFS=$'\n' read -r -d '' -a values_loopia <<< "$VALUE_LOOPIA"

            # Determine the maximum length for comparison
            max_length=${#values_one[@]}
            if [[ ${#values_loopia[@]} -gt $max_length ]]; then
                max_length=${#values_loopia[@]}
            fi

            # Compare values index by index for each subdomain
            for ((i=0; i<max_length; i++)); do
                value_ns1="${values_one[i]:-N/A}"  # Default to N/A if not set
                value_ns2="${values_loopia[i]:-N/A}"  # Default to N/A if not set

                # Determine comparison status
                if [[ "$value_ns1" == "$value_ns2" ]]; then
                    COMPARES="yes"
                else
                    COMPARES="no"
                fi

                # Print the result for the subdomain
                printf "%-10s | %-30s | %-30s | %-30s | %-10s\n" "$record" "$subdomain" "$value_ns1" "$value_ns2" "$COMPARES"
            done
        done
    done
fi
