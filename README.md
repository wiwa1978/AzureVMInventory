# VM Inventory Generator

A bash script that generates a CSV inventory of Azure Virtual Machines 

## What it does

This script:
- Discovers all VMs in a specified Azure subscription or resource group
- Collects VM specifications (cores, memory, disk sizes)
- Retrieves CPU utilization metrics from Azure Monitor
- Retrieves memory utilization metrics from Log Analytics (if configured)
- Outputs a CSV file

## Prerequisites

- **Azure CLI** (`az`) installed and configured
- **jq** installed for JSON parsing
- **Bash** shell (Linux, macOS, WSL on Windows, or Git Bash)
- Azure account with read access to the target subscription
- (Optional) Log Analytics workspace with VM Insights enabled for memory metrics

### Install prerequisites

```bash
# Ubuntu/Debian
sudo apt-get install jq

# macOS
brew install jq

# Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
```

### Login to Azure

```bash
az login
```

## Usage

```bash
./generate_azure_migrate_csv.sh -s <subscription_id> [options]
```

### Required Arguments

| Flag | Description |
|------|-------------|
| `-s` | Azure Subscription ID |

### Optional Arguments

| Flag | Description | Default |
|------|-------------|---------|
| `-g` | Resource Group name | (entire subscription) |
| `-w` | Log Analytics Workspace name | (none - memory metrics skipped) |
| `-r` | Log Analytics Workspace Resource Group | (same as `-g`) |
| `-o` | Output CSV file path | `./azure_migrate_vm_inventory.csv` |
| `-l` | Lookback period in hours for metrics | `168` (7 days) |
| `-a` | Aggregation method: `Average`, `Max`, or `P95` | `P95` |
| `-h` | Show help message | - |

## Examples

### Basic: Scan entire subscription

```bash
./generate_azure_migrate_csv.sh -s 12345678-1234-1234-1234-123456789abc
```

### Scan a specific resource group

```bash
./generate_azure_migrate_csv.sh -s 12345678-1234-1234-1234-123456789abc -g my-resource-group
```

### Include memory metrics from Log Analytics

```bash
./generate_azure_migrate_csv.sh \
  -s 12345678-1234-1234-1234-123456789abc \
  -g my-resource-group \
  -w my-log-analytics-workspace \
  -r my-la-resource-group
```

### Custom output file and 30-day lookback

```bash
./generate_azure_migrate_csv.sh \
  -s 12345678-1234-1234-1234-123456789abc \
  -g production-rg \
  -o ./production_vm_inventory.csv \
  -l 720
```

### Use average instead of P95 for metrics

```bash
./generate_azure_migrate_csv.sh \
  -s 12345678-1234-1234-1234-123456789abc \
  -g my-rg \
  -a Average
```

## Output

The script generates two files:

1. **CSV file** (`azure_migrate_vm_inventory.csv`) - Import this into Azure Migrate
2. **Log file** (`azure_migrate_vm_inventory_YYYYMMDD_HHMMSS.log`) - Detailed execution log

### CSV Columns

The CSV follows the official Azure Migrate import template format:

| Column | Description |
|--------|-------------|
| *Server name | VM name (required) |
| IP addresses | Private IP address |
| *Cores | Number of vCPUs (required) |
| *Memory (In MB) | RAM in megabytes (required) |
| *OS name | Operating system (required) |
| OS version | OS version |
| OS architecture | x64 or x86 |
| Server type | Virtual |
| Hypervisor | Hyper-V (Azure runs on Hyper-V) |
| CPU utilization percentage | P95/Avg/Max CPU usage |
| Memory utilization percentage | P95/Avg/Max memory usage |
| Number of disks | Total disk count |
| Disk 1 size (In GB) | OS disk size |
| ... | Additional disk and throughput columns |


## Troubleshooting

### VM size (cores/memory) shows as empty

The script tries two methods to resolve VM sizes:
1. `az vm list-sizes` (fast, but may not have newer VM sizes)
2. `az vm list-skus` (slower, but more complete)

For very new VM sizes, both may fail. Check the log file for details.

### Memory metrics are empty

Memory utilization requires:
- A Log Analytics workspace configured with the `-w` and `-r` options
- VMs must have the Azure Monitor Agent or VM Insights enabled
- Data must exist in either `InsightsMetrics` or `Perf` tables

### IP address not found

This can happen if:
- The VM has no NIC attached
- The NIC has no private IP configured
- Permissions issue reading NIC details

### Script is slow

The main slowdowns are:
- `az vm list-skus` can take 1-2 minutes per location (only used as fallback)
- Log Analytics queries for memory metrics
- Individual disk lookups

For large environments, consider running the script during off-hours.

## Log Levels

The log file includes:

- **INFO** - Progress and results
- **DEBUG** - Detailed API calls and intermediate values
- **WARN** - Non-fatal issues (missing data, fallbacks used)
- **ERROR** - Failures that prevent processing

## Contributing

Feel free to submit issues, fork the repository, and create pull requests for any improvements.

## 📄 License

This project is provided as-is for educational and testing purposes.

## ⚠️ Disclaimer

**IMPORTANT:** Although these scripts have been tested, they are **NOT recommended for use in production environments** without thorough testing and validation in your specific environment.

**No Warranty:** This software is provided "as is", without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose, and non-infringement.

**No Responsibility:** The authors and contributors of this project take no responsibility for any damage, data loss, service interruptions, or other issues that may arise from the use of these scripts. Use at your own risk.

**Production Use:** Before using these scripts in any production environment:

- Thoroughly test in a non-production environment
- Review and understand all code before execution
- Ensure proper backup and recovery procedures are in place
- Validate compatibility with your specific Azure environment and policies
- Consider having the scripts reviewed by your IT security and operations teams

**Your Responsibility:** It is your responsibility to ensure these scripts are suitable for your environment and comply with your organization's policies and procedures.
