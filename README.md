# Shell Helper Scripts

A collection of useful shell scripts to enhance productivity for developers, with a focus on Git and URL management.

## Scripts included

### check-urls.sh

A script that checks if redirect rules defined in CSV format are correctly implemented.

**Features:**
- Validates URL redirects against expected rules
- Supports reading rules from a file or directly from the command line
- Follows redirect chains and verifies final destinations
- Provides detailed reporting with success/failure status

**Usage:**
```bash
check-urls.sh -f rules.csv
check-urls.sh -r "301,example.com,/old-page,https://example.com/new-page"
```

### semver-tag.sh

Creates and pushes a new semantic version tag for Git repositories.

**Features:**
- Automatically increments semantic version numbers (major, minor, patch)
- Supports annotated tags with custom messages
- Pushes tags to remote repository
- Follows semantic versioning conventions

**Usage:**
```bash
semver-tag.sh                     # Increment patch: 1.2.3 -> 1.2.4
semver-tag.sh --minor             # Increment minor: 1.2.3 -> 1.3.0
semver-tag.sh --major             # Increment major: 1.2.3 -> 2.0.0
semver-tag.sh 'Bug fix release'   # With message
```

### test-tag.sh

Creates and pushes a test tag with timestamp and branch name for Git repositories.

**Features:**
- Automatically generates test tags with timestamps
- Uses current branch name or custom name
- Sanitizes tag names for compatibility
- Supports annotated tags with custom messages

**Usage:**
```bash
test-tag.sh                           # Use current branch name
test-tag.sh --name demo               # Use custom name for test tag
test-tag.sh 'QA build for testing'    # With tag message
```

### DNS Comparison Tool (`compare-dns.sh`)
This script compares DNS records between two nameservers for a specific domain and its subdomains. It's particularly useful for verifying DNS propagation, validating changes across different DNS providers, or troubleshooting DNS-related issues.

#### Features
- Compare multiple DNS record types (A, AAAA, MX, TXT, CNAME, NS, SRV) between two nameservers
- Support for checking both the main domain and specified subdomains
- Clear tabular output showing differences between nameservers
- Special handling for multi-value records like MX and TXT

#### Usage
```bash
compare-dns.sh --domain <domain> --ns1 <nameserver1> --ns2 <nameserver2> [--subdomains <subdomain1,subdomain2,...>]
```

#### Parameters
- `--domain`: The domain to check (required)
- `--ns1`: First nameserver to query (required)
- `--ns2`: Second nameserver to query (required)
- `--subdomains`: Comma-separated list of subdomains to check (optional)

#### Examples
Compare DNS records for example.com between two nameservers:
```bash
compare-dns.sh --domain example.com --ns1 8.8.8.8 --ns2 1.1.1.1
```

Compare DNS records including specific subdomains:
```bash
compare-dns.sh --domain example.com --ns1 ns1.provider1.com --ns2 ns1.provider2.com --subdomains www,api,mail
```

Check if DNS changes have propagated from primary to secondary nameserver:
```bash
compare-dns.sh --domain example.com --ns1 primary-ns.example.com --ns2 secondary-ns.example.com
```

#### Output
The script outputs a table with the following columns:
- RECORD: The DNS record type (A, AAAA, MX, etc.)
- Domain/Subdomain: The domain or subdomain being checked
- ns1: The record value from the first nameserver
- ns2: The record value from the second nameserver
- Compares?: Indicates whether the records match ("yes" or "no")

## Installation

You can install these shell helper scripts as aliases in your shell configuration to make them easily accessible from anywhere.

### Option 1: Add to PATH

1. Clone this repository:
   ```bash
   git clone https://github.com/johanhermansson/shell-helpers.git
   ```

2. Make the scripts executable:
   ```bash
   chmod +x /path/to/shell-helpers/*.sh
   ```

3. Add the directory to your PATH in your `~/.bashrc`, `~/.zshrc`, `~/.zprofile` or equivalent shell configuration file:
   ```bash
   export PATH="$PATH:/path/to/shell-helpers"
   ```

4. Reload your shell configuration:
   ```bash
   source ~/.bashrc  # or ~/.zshrc if using zsh
   ```

### Option 2: Create Aliases

Add aliases to your `~/.bashrc`, `~/.zshrc`, or equivalent shell configuration file:

```bash
# URL redirect checker
alias check-urls="/path/to/shell-helpers/check-urls.sh"

# Git semantic versioning
alias semver-tag="/path/to/shell-helpers/semver-tag.sh"

# Git test tagging
alias test-tag="/path/to/shell-helpers/test-tag.sh"

# DNS comparison tool
alias compare-dns="/path/to/shell-helpers/compare-dns.sh"
```

Then reload your shell configuration:
```bash
source ~/.bashrc  # or ~/.zshrc if using zsh
```

### Option 3: Create Shell Functions

For more flexibility, you can create shell functions in your `~/.bashrc`, `~/.zshrc`, or equivalent shell configuration file:

```bash
# URL redirect checker
check-urls() {
    /path/to/shell-helpers/check-urls.sh "$@"
}

# Git semantic versioning
semver-tag() {
    /path/to/shell-helpers/semver-tag.sh "$@"
}

# Git test tagging
test-tag() {
    /path/to/shell-helpers/test-tag.sh "$@"
}

# DNS comparison tool
compare-dns() {
    /path/to/shell-helpers/compare-dns.sh "$@"
}
```

Then reload your shell configuration:
```bash
source ~/.bashrc  # or ~/.zshrc if using zsh
```

## Usage Examples

### Checking URL Redirects

```bash
# Check redirects from a CSV file
check-urls -f redirects.csv

# Check a specific redirect rule
check-urls -r "301,example.com,/old-page,https://example.com/new-page"

# Show verbose output
check-urls -f redirects.csv -v
```

### Managing Git Tags

```bash
# Create a new patch version
semver-tag

# Create a new minor version with a message
semver-tag --minor "Added new features"

# Create a test tag using the current branch name
test-tag

# Create a test tag with a custom name and message
test-tag --name release-candidate "RC for version 2.0"
```

### Comparing DNS Records

```bash
# Compare DNS records for example.com between two nameservers
compare-dns.sh --domain example.com --ns1 8.8.8.8 --ns2 1.1.1.1

# Compare DNS records including specific subdomains
compare-dns.sh --domain example.com --ns1 ns1.provider1.com --ns2 ns1.provider2.com --subdomains www,api,mail

# Check if DNS changes have propagated from primary to secondary nameserver
compare-dns.sh --domain example.com --ns1 primary-ns.example.com --ns2 secondary-ns.example.com
```

## Customization

These scripts are designed to be modular and easy to customize. Feel free to modify them to suit your specific needs:

- Add new features or options
- Adjust default behaviors
- Integrate with other tools in your workflow

## Troubleshooting

### Common Issues

1. **Permission denied**: Make sure the scripts are executable
   ```bash
   chmod +x /path/to/script.sh
   ```

2. **Command not found**: Ensure the scripts are in your PATH or that your aliases are correctly defined

3. **Git errors**: Make sure you're running the scripts within a Git repository

### Getting Help

Each script includes a help option that provides detailed usage information:

```bash
check-urls.sh --help
semver-tag.sh --help
test-tag.sh --help
compare-dns.sh --help
```

## Contributing

Contributions are welcome! If you have improvements or new shell helper scripts to add, please submit a pull request.

## License

[GPL-3.0 License](LICENSE)