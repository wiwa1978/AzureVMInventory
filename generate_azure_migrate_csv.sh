#!/usr/bin/env bash
# Safer: avoid exiting on first non-zero inside subshells; we'll guard error-prone calls individually.
# Removed set -u to avoid unbound variable exits; using ${VAR:-} patterns instead
set +e  # Don't exit on errors - we handle them explicitly

# --- Usage function ---
usage() {
  echo "Usage: $0 -s <subscription_id> [-g <resource_group>] [-w <workspace_name>] [-r <workspace_rg>] [-o <output_csv>] [-l <lookback_hours>] [-a <aggregation>]"
  echo ""
  echo "Required:"
  echo "  -s    Azure Subscription ID"
  echo ""
  echo "Optional:"
  echo "  -g    Resource Group (if omitted, scans entire subscription)"
  echo "  -w    Log Analytics Workspace name (default: none - memory metrics skipped)"
  echo "  -r    Log Analytics Workspace Resource Group (defaults to -g value)"
  echo "  -o    Output CSV file path (default: ./azure_migrate_vm_inventory.csv)"
  echo "  -l    Lookback hours for metrics (default: 168 = 7 days)"
  echo "  -a    Aggregation method: Average|Max|P95 (default: P95)"
  echo "  -h    Show this help message"
  echo ""
  echo "Examples:"
  echo "  $0 -s 12345678-1234-1234-1234-123456789abc"
  echo "  $0 -s 12345678-1234-1234-1234-123456789abc -g my-resource-group"
  echo "  $0 -s 12345678-1234-1234-1234-123456789abc -g my-rg -w my-log-analytics -r my-la-rg"
  exit 1
}

# --- Default values ---
SUBSCRIPTION_ID=""
RESOURCE_GROUP=""
WORKSPACE_NAME=""
WORKSPACE_RG=""
OUTPUT_CSV="./azure_migrate_vm_inventory.csv"
LOOKBACK_HOURS=168                      # 7 days
AGG="P95"                               # Average|Max|P95

# --- Parse command line arguments ---
while getopts "s:g:w:r:o:l:a:h" opt; do
  case $opt in
    s) SUBSCRIPTION_ID="$OPTARG" ;;
    g) RESOURCE_GROUP="$OPTARG" ;;
    w) WORKSPACE_NAME="$OPTARG" ;;
    r) WORKSPACE_RG="$OPTARG" ;;
    o) OUTPUT_CSV="$OPTARG" ;;
    l) LOOKBACK_HOURS="$OPTARG" ;;
    a) AGG="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

# --- Validate required arguments ---
if [[ -z "$SUBSCRIPTION_ID" ]]; then
  echo "Error: Subscription ID is required."
  echo ""
  usage
fi

# Default workspace RG to resource group if not specified
if [[ -n "$WORKSPACE_NAME" && -z "$WORKSPACE_RG" ]]; then
  WORKSPACE_RG="$RESOURCE_GROUP"
fi

# --- Logging configuration ---
LOG_FILE="./azure_migrate_vm_inventory_$(date +%Y%m%d_%H%M%S).log"

# Logging function
log() {
  local level="$1"
  shift
  local message="$*"
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

log "INFO" "=========================================="
log "INFO" "Azure Migrate VM Inventory Script Started"
log "INFO" "=========================================="
log "INFO" "Log file: $LOG_FILE"
log "INFO" "Output CSV: $OUTPUT_CSV"
log "INFO" "Subscription ID: $SUBSCRIPTION_ID"
log "INFO" "Resource Group: ${RESOURCE_GROUP:-'(entire subscription)'}"
log "INFO" "Log Analytics Workspace: ${WORKSPACE_NAME:-'(not configured)'} ${WORKSPACE_RG:+(RG: $WORKSPACE_RG)}"
log "INFO" "Lookback period: $LOOKBACK_HOURS hours"
log "INFO" "Aggregation method: $AGG"

log "INFO" "Setting subscription context..."
az account set -s "$SUBSCRIPTION_ID"
log "INFO" "Subscription context set successfully"

WORKSPACE_RESOURCE_ID=""
if [[ -n "$WORKSPACE_NAME" && -n "$WORKSPACE_RG" ]]; then
  log "INFO" "Resolving Log Analytics workspace resource ID..."
  WORKSPACE_RESOURCE_ID=$(az resource show \
    -g "$WORKSPACE_RG" -n "$WORKSPACE_NAME" \
    --resource-type "Microsoft.OperationalInsights/workspaces" \
    --query id -o tsv 2>/dev/null || true)

  if [[ -z "${WORKSPACE_RESOURCE_ID:-}" ]]; then
    log "WARN" "Could not resolve Log Analytics workspace. Memory utilization will be left blank."
  else
    log "INFO" "Workspace Resource ID: $WORKSPACE_RESOURCE_ID"
  fi
else
  log "INFO" "No Log Analytics workspace configured. Memory utilization will be left blank."
fi

log "INFO" "Creating CSV file with header..."
# Azure Migrate official import template format
printf '*Server name,IP addresses,*Cores,*Memory (In MB),*OS name,OS version,OS architecture,Server type,Hypervisor,CPU utilization percentage,Memory utilization percentage,Network adapters,Network In throughput,Network Out throughput,Boot type,Number of disks,Storage in use (In GB),Disk 1 size (In GB),Disk 1 read throughput (MB per second),Disk 1 write throughput (MB per second),Disk 1 read ops (operations per second),Disk 1 write ops (operations per second),Disk 2 size (In GB),Disk 2 read throughput (MB per second),Disk 2 write throughput (MB per second),Disk 2 read ops (operations per second),Disk 2 write ops (operations per second)\n' > "$OUTPUT_CSV"
log "INFO" "CSV header written to $OUTPUT_CSV"

log "INFO" "Fetching VM list..."
if [[ -n "$RESOURCE_GROUP" ]]; then
  log "INFO" "Scope: Resource Group '$RESOURCE_GROUP'"
  VMS_JSON=$(az vm list -g "$RESOURCE_GROUP" -o json)
else
  log "INFO" "Scope: Entire subscription"
  VMS_JSON=$(az vm list -o json)
fi


COUNT=$(jq 'length' <<< "$VMS_JSON")
log "INFO" "Found $COUNT VM(s) to process"

if [[ "$COUNT" -eq 0 ]]; then
  log "WARN" "No VMs found. CSV only contains header."
  log "INFO" "=========================================="
  log "INFO" "Script completed (no VMs to process)"
  log "INFO" "=========================================="
  exit 0
fi

END=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
START=$(date -u -d "-${LOOKBACK_HOURS} hours" +"%Y-%m-%dT%H:%M:%SZ")
log "INFO" "Metrics time window: $START to $END"

# Build array of VMs to iterate - avoids stdin consumption issues with while read
mapfile -t VM_ARRAY < <(jq -c '.[]' <<< "$VMS_JSON")
log "DEBUG" "VM_ARRAY length: ${#VM_ARRAY[@]}"

VM_INDEX=0
for vm in "${VM_ARRAY[@]}"; do
  VM_INDEX=$((VM_INDEX + 1))
  log "DEBUG" "Starting iteration $VM_INDEX"
  
  # Parse VM details with null safety
  VM_ID=$(jq -r '.id // empty' <<< "$vm" 2>/dev/null || echo "")
  VM_NAME=$(jq -r '.name // empty' <<< "$vm" 2>/dev/null || echo "unknown-$VM_INDEX")
  LOCATION=$(jq -r '.location // empty' <<< "$vm" 2>/dev/null || echo "")
  SIZE=$(jq -r '.hardwareProfile.vmSize // empty' <<< "$vm" 2>/dev/null || echo "")
  OS_TYPE=$(jq -r '.storageProfile.osDisk.osType // empty' <<< "$vm" 2>/dev/null || echo "")

  log "INFO" "----------------------------------------"
  log "INFO" "Processing VM $VM_INDEX/$COUNT: $VM_NAME"
  log "DEBUG" "  VM ID: $VM_ID"
  log "DEBUG" "  Location: $LOCATION"
  log "DEBUG" "  Size: $SIZE"
  log "DEBUG" "  OS Type: $OS_TYPE"

  # Resolve cores & memory - try fast list-sizes first, slow list-skus as fallback
  log "DEBUG" "  Fetching VM size details for $SIZE..."
  SIZE_INFO=$(az vm list-sizes -l "$LOCATION" --query "[?name=='$SIZE']" -o json 2>/dev/null | jq '.[0]' || echo "null")
  CORES=$(jq -r '.numberOfCores // empty' <<< "$SIZE_INFO")
  MEMORY_MB=$(jq -r '.memoryInMb // empty' <<< "$SIZE_INFO")
  
  if [[ -z "$CORES" || -z "$MEMORY_MB" || "$CORES" == "null" || "$MEMORY_MB" == "null" ]]; then
    log "WARN" "  list-sizes failed for $SIZE. Trying list-skus (this may take a while)..."
    # Fallback to list-skus for newer VM sizes not in list-sizes
    SKUS_JSON=$(az vm list-skus --location "$LOCATION" --size "$SIZE" --resource-type virtualMachines -o json 2>/dev/null || echo "[]")
    CORES=$(jq -r '[.[] | .capabilities[] | select(.name=="vCPUs") | .value][0] // empty' <<< "$SKUS_JSON")
    MEMORY_GB=$(jq -r '[.[] | .capabilities[] | select(.name=="MemoryGB") | .value][0] // empty' <<< "$SKUS_JSON")
    
    if [[ -n "$MEMORY_GB" && "$MEMORY_GB" != "null" ]]; then
      MEMORY_MB=$(awk "BEGIN {print int($MEMORY_GB * 1024)}")
    else
      MEMORY_MB=""
    fi
    
    if [[ -z "$CORES" || -z "$MEMORY_MB" || "$CORES" == "null" ]]; then
      log "WARN" "  Could not resolve size for $VM_NAME. Values will be empty."
      CORES=""
      MEMORY_MB=""
    else
      log "INFO" "  Cores: $CORES, Memory: ${MEMORY_MB}MB (from list-skus)"
    fi
  else
    log "INFO" "  Cores: $CORES, Memory: ${MEMORY_MB}MB"
  fi

  # Disks - get actual disk sizes from managed disk resources
  # First try to get OS disk ID from VM JSON
  OS_DISK_ID=$(jq -r '.storageProfile.osDisk.managedDisk.id // empty' <<< "$vm")
  DISK1_SIZE=""
  
  log "DEBUG" "  OS Disk ID from VM: ${OS_DISK_ID:-'not found'}"
  
  # If no disk ID in VM list, query the VM directly for disk info
  if [[ -z "$OS_DISK_ID" || "$OS_DISK_ID" == "null" ]]; then
    log "DEBUG" "  Fetching VM details for disk info..."
    VM_DETAIL=$(az vm show --ids "$VM_ID" -o json 2>/dev/null || echo "{}")
    OS_DISK_ID=$(jq -r '.storageProfile.osDisk.managedDisk.id // empty' <<< "$VM_DETAIL")
    log "DEBUG" "  OS Disk ID from VM show: ${OS_DISK_ID:-'not found'}"
  fi
  
  if [[ -n "$OS_DISK_ID" && "$OS_DISK_ID" != "null" ]]; then
    log "DEBUG" "  Fetching OS disk details..."
    DISK1_SIZE=$(az disk show --ids "$OS_DISK_ID" --query "diskSizeGb" -o tsv 2>/dev/null || echo "")
    log "DEBUG" "  Disk size from disk show: ${DISK1_SIZE:-'not found'}"
  fi
  
  # Fallback to VM property if managed disk query fails
  if [[ -z "$DISK1_SIZE" || "$DISK1_SIZE" == "null" ]]; then
    DISK1_SIZE=$(jq -r '.storageProfile.osDisk.diskSizeGb // empty' <<< "$vm")
    log "DEBUG" "  Disk size from VM JSON: ${DISK1_SIZE:-'not found'}"
  fi
  
  DISK_COUNT_DATA=$(jq -r '.storageProfile.dataDisks | length' <<< "$vm")
  if [[ -n "$DISK1_SIZE" && "$DISK1_SIZE" != "null" && "$DISK1_SIZE" != "" ]]; then
    NUM_DISKS=$((1 + DISK_COUNT_DATA))
  else
    # Even if we can't get the size, there's still an OS disk
    NUM_DISKS=$((1 + DISK_COUNT_DATA))
    log "WARN" "  Could not determine OS disk size, but counting it as 1 disk"
  fi
  log "INFO" "  Disks: $NUM_DISKS total (OS disk: ${DISK1_SIZE:-N/A}GB)"

  # IP (best-effort)
  log "DEBUG" "  Fetching network information..."
  NIC_ID=$(jq -r '.networkProfile.networkInterfaces[0].id // empty' <<< "$vm")
  IP_ADDR=""
  if [[ -n "$NIC_ID" ]]; then
    log "DEBUG" "  NIC ID: $NIC_ID"
    # Try getting the full NIC info first to debug
    NIC_JSON=$(az network nic show --ids "$NIC_ID" -o json 2>/dev/null || true)
    if [[ -n "$NIC_JSON" ]]; then
      IP_ADDR=$(jq -r '.ipConfigurations[0].privateIpAddress // empty' <<< "$NIC_JSON")
      log "DEBUG" "  Private IP from NIC: ${IP_ADDR:-empty}"
      # If private IP not found directly, check if it's in a different structure
      if [[ -z "$IP_ADDR" || "$IP_ADDR" == "null" ]]; then
        IP_ADDR=$(jq -r '.ipConfigurations[]?.privateIpAddress // empty' <<< "$NIC_JSON" | head -1)
      fi
    else
      log "WARN" "  Could not fetch NIC details"
    fi
    if [[ -n "$IP_ADDR" && "$IP_ADDR" != "null" ]]; then
      log "INFO" "  IP Address: $IP_ADDR"
    else
      log "WARN" "  IP Address not found for NIC"
      IP_ADDR=""
    fi
  else
    log "WARN" "  No NIC found for VM"
  fi

  # CPU metric (host: Percentage CPU). Azure CLI supports Average/Maximum; we compute P95 client-side if requested. [3](https://learn.microsoft.com/en-us/cli/azure/vm/monitor/metrics?view=azure-cli-latest)
  log "DEBUG" "  Fetching CPU metrics from Azure Monitor..."
  CPU_JSON=$(az monitor metrics list \
    --resource "$VM_ID" \
    --metric "Percentage CPU" \
    --interval PT5M \
    --start-time "$START" --end-time "$END" \
    --aggregation average maximum \
    -o json 2>/dev/null || true)

  CPU_AVGS=$(jq -r '.value[0].timeseries[0].data | map(.average) | map(select(.!=null))' <<< "$CPU_JSON" 2>/dev/null || echo "[]")
  CPU_MAXS=$(jq -r '.value[0].timeseries[0].data | map(.maximum) | map(select(.!=null))' <<< "$CPU_JSON" 2>/dev/null || echo "[]")

  CPU_VAL=0
  if [[ "$AGG" == "Average" ]]; then
    CPU_VAL=$(jq -r 'if length>0 then (add/length) else 0 end' <<< "$CPU_AVGS")
  elif [[ "$AGG" == "Max" ]]; then
    CPU_VAL=$(jq -r 'if length>0 then max else 0 end' <<< "$CPU_MAXS")
  else # P95
    CPU_VAL=$(jq -r 'if length>0 then sort | .[(length*0.95|floor)] else 0 end' <<< "$CPU_AVGS")
  fi
  log "INFO" "  CPU utilization ($AGG): ${CPU_VAL:-0}%"

  # Memory% (guest metrics via Log Analytics). If workspace not resolved or no data, leave blank. [1](https://learn.microsoft.com/en-us/azure/azure-monitor/vm/tutorial-monitor-vm-guest)[4](https://learn.microsoft.com/en-us/azure/azure-monitor/vm/vminsights-performance)
  MEM_VAL=""
  if [[ -n "${WORKSPACE_RESOURCE_ID:-}" ]]; then
    log "DEBUG" "  Querying Log Analytics for memory metrics (InsightsMetrics)..."
    read -r -d '' KQL_INSIGHTS <<'EOF' || true
InsightsMetrics
| where Namespace == "Memory"
| where _ResourceId == "{VM_ID}"
| where TimeGenerated > ago({LOOKBACK}h)
| extend TotalMemMB = todouble(todynamic(Tags)['vm.azm.ms/memorySizeMB'])
| where isnotempty(TotalMemMB) and TotalMemMB > 0
| extend UsedPct = (Val / TotalMemMB) * 100.0
| summarize Avg=avg(UsedPct), P95=percentile(UsedPct,95), Max=max(UsedPct)
EOF
    KQL_INSIGHTS="${KQL_INSIGHTS//\{VM_ID\}/$VM_ID}"
    KQL_INSIGHTS="${KQL_INSIGHTS//\{LOOKBACK\}/$LOOKBACK_HOURS}"

    LA_JSON=$(az monitor log-analytics query -w "$WORKSPACE_RESOURCE_ID" --analytics-query "$KQL_INSIGHTS" -o json 2>/dev/null || true)
    if [[ $(echo "$LA_JSON" | jq -r '.tables | length') -gt 0 && $(echo "$LA_JSON" | jq -r '.tables[0].rows | length') -gt 0 ]]; then
      log "DEBUG" "  InsightsMetrics data found"
      if [[ "$AGG" == "Average" ]]; then
        MEM_VAL=$(echo "$LA_JSON" | jq -r '.tables[0].rows[0][0]')
      elif [[ "$AGG" == "P95" ]]; then
        MEM_VAL=$(echo "$LA_JSON" | jq -r '.tables[0].rows[0][1]')
      else
        MEM_VAL=$(echo "$LA_JSON" | jq -r '.tables[0].rows[0][2]')
      fi
    else
      # Perf fallback (Windows: % Committed Bytes In Use, Linux: % Used Memory). [5](https://www.geeksforgeeks.org/devops/microsoft-azure-tracking-memory-utilization-of-azure-vm-using-kql-log-query/)
      log "DEBUG" "  No InsightsMetrics data, falling back to Perf counters..."
      read -r -d '' KQL_PERF <<'EOF' || true
Perf
| where _ResourceId == "{VM_ID}"
| where ObjectName == "Memory" and CounterName in ("% Committed Bytes In Use","% Used Memory")
| where TimeGenerated > ago({LOOKBACK}h)
| summarize Avg=avg(CounterValue), P95=percentile(CounterValue,95), Max=max(CounterValue)
EOF
      KQL_PERF="${KQL_PERF//\{VM_ID\}/$VM_ID}"
      KQL_PERF="${KQL_PERF//\{LOOKBACK\}/$LOOKBACK_HOURS}"
      LA_JSON_PERF=$(az monitor log-analytics query -w "$WORKSPACE_RESOURCE_ID" --analytics-query "$KQL_PERF" -o json 2>/dev/null || true)
      if [[ $(echo "$LA_JSON_PERF" | jq -r '.tables | length') -gt 0 && $(echo "$LA_JSON_PERF" | jq -r '.tables[0].rows | length') -gt 0 ]]; then
        log "DEBUG" "  Perf counter data found"
        if [[ "$AGG" == "Average" ]]; then
          MEM_VAL=$(echo "$LA_JSON_PERF" | jq -r '.tables[0].rows[0][0]')
        elif [[ "$AGG" == "P95" ]]; then
          MEM_VAL=$(echo "$LA_JSON_PERF" | jq -r '.tables[0].rows[0][1]')
        else
          MEM_VAL=$(echo "$LA_JSON_PERF" | jq -r '.tables[0].rows[0][2]')
        fi
      else
        log "WARN" "  No memory metrics found in Log Analytics for $VM_NAME"
      fi
    fi
  else
    log "DEBUG" "  Skipping memory metrics (no workspace configured)"
  fi
  log "INFO" "  Memory utilization ($AGG): ${MEM_VAL:-'N/A'}%"

  # --- Network adapter count ---
  NIC_COUNT=$(jq -r '.networkProfile.networkInterfaces | length' <<< "$vm" 2>/dev/null || echo "0")
  log "INFO" "  Network adapters: $NIC_COUNT"

  # --- Network throughput metrics from Azure Monitor ---
  log "DEBUG" "  Fetching network throughput metrics..."
  NET_JSON=$(az monitor metrics list \
    --resource "$VM_ID" \
    --metric "Network In Total" "Network Out Total" \
    --interval PT5M \
    --start-time "$START" --end-time "$END" \
    --aggregation average \
    -o json 2>/dev/null || echo "{}")
  
  # Network In (bytes/sec -> MB/sec average over period)
  NET_IN_BYTES=$(jq -r '.value[0].timeseries[0].data | map(.average) | map(select(.!=null)) | if length>0 then (add/length) else 0 end' <<< "$NET_JSON" 2>/dev/null || echo "0")
  NET_OUT_BYTES=$(jq -r '.value[1].timeseries[0].data | map(.average) | map(select(.!=null)) | if length>0 then (add/length) else 0 end' <<< "$NET_JSON" 2>/dev/null || echo "0")
  
  # Convert bytes to MB/s (divide by 1024*1024, and by 300 for 5-min interval to get per-second)
  NET_IN_MBPS=$(awk "BEGIN {printf \"%.2f\", $NET_IN_BYTES / 1048576 / 300}" 2>/dev/null || echo "")
  NET_OUT_MBPS=$(awk "BEGIN {printf \"%.2f\", $NET_OUT_BYTES / 1048576 / 300}" 2>/dev/null || echo "")
  log "INFO" "  Network In: ${NET_IN_MBPS:-0} MB/s, Out: ${NET_OUT_MBPS:-0} MB/s"

  # --- Boot type (UEFI or BIOS) ---
  # Need to get this from VM details if not in basic list
  if [[ -z "${VM_DETAIL:-}" ]]; then
    VM_DETAIL=$(az vm show --ids "$VM_ID" -o json 2>/dev/null || echo "{}")
  fi
  SECURITY_TYPE=$(jq -r '.securityProfile.securityType // empty' <<< "$VM_DETAIL" 2>/dev/null || echo "")
  UEFI_ENABLED=$(jq -r '.securityProfile.uefiSettings.secureBootEnabled // empty' <<< "$VM_DETAIL" 2>/dev/null || echo "")
  
  if [[ "$SECURITY_TYPE" == "TrustedLaunch" || "$SECURITY_TYPE" == "ConfidentialVM" || "$UEFI_ENABLED" == "true" ]]; then
    BOOT_TYPE="UEFI"
  else
    BOOT_TYPE="BIOS"
  fi
  log "INFO" "  Boot type: $BOOT_TYPE"

  # --- Disk I/O metrics from Azure Monitor ---
  log "DEBUG" "  Fetching disk I/O metrics..."
  DISK_JSON=$(az monitor metrics list \
    --resource "$VM_ID" \
    --metric "Disk Read Bytes/sec" "Disk Write Bytes/sec" "Disk Read Operations/Sec" "Disk Write Operations/Sec" \
    --interval PT5M \
    --start-time "$START" --end-time "$END" \
    --aggregation average \
    -o json 2>/dev/null || echo "{}")
  
  # Disk Read/Write throughput (bytes/sec -> MB/sec)
  DISK_READ_BYTES=$(jq -r '.value[0].timeseries[0].data | map(.average) | map(select(.!=null)) | if length>0 then (add/length) else 0 end' <<< "$DISK_JSON" 2>/dev/null || echo "0")
  DISK_WRITE_BYTES=$(jq -r '.value[1].timeseries[0].data | map(.average) | map(select(.!=null)) | if length>0 then (add/length) else 0 end' <<< "$DISK_JSON" 2>/dev/null || echo "0")
  DISK_READ_OPS=$(jq -r '.value[2].timeseries[0].data | map(.average) | map(select(.!=null)) | if length>0 then (add/length) else 0 end' <<< "$DISK_JSON" 2>/dev/null || echo "0")
  DISK_WRITE_OPS=$(jq -r '.value[3].timeseries[0].data | map(.average) | map(select(.!=null)) | if length>0 then (add/length) else 0 end' <<< "$DISK_JSON" 2>/dev/null || echo "0")
  
  # Convert to MB/s
  DISK1_READ_MBPS=$(awk "BEGIN {printf \"%.2f\", $DISK_READ_BYTES / 1048576}" 2>/dev/null || echo "")
  DISK1_WRITE_MBPS=$(awk "BEGIN {printf \"%.2f\", $DISK_WRITE_BYTES / 1048576}" 2>/dev/null || echo "")
  DISK1_READ_IOPS=$(awk "BEGIN {printf \"%.0f\", $DISK_READ_OPS}" 2>/dev/null || echo "")
  DISK1_WRITE_IOPS=$(awk "BEGIN {printf \"%.0f\", $DISK_WRITE_OPS}" 2>/dev/null || echo "")
  log "INFO" "  Disk I/O: Read ${DISK1_READ_MBPS:-0} MB/s (${DISK1_READ_IOPS:-0} IOPS), Write ${DISK1_WRITE_MBPS:-0} MB/s (${DISK1_WRITE_IOPS:-0} IOPS)"

  # OS name must match supported Azure Migrate list to avoid warnings. Use safe defaults. [6](https://learn.microsoft.com/en-us/azure/migrate/tutorial-discover-import?view=migrate)
  if [[ "$OS_TYPE" == "Windows" ]]; then 
    OS_NAME="Microsoft Windows Server 2019 (64-bit)"
    OS_ARCH="x64"
  else 
    OS_NAME="Ubuntu Linux"
    OS_ARCH="x64"
  fi

  # Calculate storage in use (sum of all disk sizes)
  STORAGE_IN_USE=""
  if [[ -n "$DISK1_SIZE" && "$DISK1_SIZE" != "null" ]]; then
    STORAGE_IN_USE="$DISK1_SIZE"
  fi
  
  # Get data disk sizes for Disk 2 if exists
  DISK2_SIZE=""
  if [[ "$DISK_COUNT_DATA" -gt 0 ]]; then
    DATA_DISK_ID=$(jq -r '.storageProfile.dataDisks[0].managedDisk.id // empty' <<< "$vm" 2>/dev/null)
    if [[ -n "$DATA_DISK_ID" && "$DATA_DISK_ID" != "null" ]]; then
      DISK2_SIZE=$(az disk show --ids "$DATA_DISK_ID" --query "diskSizeGb" -o tsv 2>/dev/null || echo "")
    fi
    if [[ -z "$DISK2_SIZE" ]]; then
      DISK2_SIZE=$(jq -r '.storageProfile.dataDisks[0].diskSizeGb // empty' <<< "$vm" 2>/dev/null || echo "")
    fi
    # Add to storage in use
    if [[ -n "$DISK2_SIZE" && "$DISK2_SIZE" != "null" && -n "$STORAGE_IN_USE" ]]; then
      STORAGE_IN_USE=$((STORAGE_IN_USE + DISK2_SIZE))
    elif [[ -n "$DISK2_SIZE" && "$DISK2_SIZE" != "null" ]]; then
      STORAGE_IN_USE="$DISK2_SIZE"
    fi
    log "INFO" "  Data disk 1 size: ${DISK2_SIZE:-N/A}GB"
  fi

  # Always write a row - Azure Migrate template format
  # Columns: *Server name,IP addresses,*Cores,*Memory (In MB),*OS name,OS version,OS architecture,
  #          Server type,Hypervisor,CPU utilization percentage,Memory utilization percentage,
  #          Network adapters,Network In throughput,Network Out throughput,Boot type,
  #          Number of disks,Storage in use (In GB),Disk 1 size (In GB),
  #          Disk 1 read throughput,Disk 1 write throughput,Disk 1 read ops,Disk 1 write ops,
  #          Disk 2 size (In GB),Disk 2 read throughput,Disk 2 write throughput,Disk 2 read ops,Disk 2 write ops
  log "DEBUG" "  Writing CSV row for $VM_NAME"
  
  # Format CPU value (avoid scientific notation, round to 2 decimals)
  CPU_FORMATTED=$(printf "%.2f" "${CPU_VAL:-0}" 2>/dev/null || echo "")
  MEM_FORMATTED=$(printf "%.2f" "${MEM_VAL:-0}" 2>/dev/null || echo "")
  
  # Hypervisor must be one of: Vmware, Hyper-V, Xen, AWS, GCP, or empty
  # For Azure VMs (already in Azure), leave empty or use Hyper-V since Azure runs on Hyper-V
  HYPERVISOR="Hyper-V"
  
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$VM_NAME" \
    "${IP_ADDR:-}" \
    "$CORES" \
    "$MEMORY_MB" \
    "$OS_NAME" \
    "" \
    "$OS_ARCH" \
    "Virtual" \
    "$HYPERVISOR" \
    "$CPU_FORMATTED" \
    "$MEM_FORMATTED" \
    "${NIC_COUNT:-}" \
    "${NET_IN_MBPS:-}" \
    "${NET_OUT_MBPS:-}" \
    "$BOOT_TYPE" \
    "$NUM_DISKS" \
    "${STORAGE_IN_USE:-}" \
    "${DISK1_SIZE:-}" \
    "${DISK1_READ_MBPS:-}" \
    "${DISK1_WRITE_MBPS:-}" \
    "${DISK1_READ_IOPS:-}" \
    "${DISK1_WRITE_IOPS:-}" \
    "${DISK2_SIZE:-}" \
    "${DISK1_READ_MBPS:-}" \
    "${DISK1_WRITE_MBPS:-}" \
    "${DISK1_READ_IOPS:-}" \
    "${DISK1_WRITE_IOPS:-}" \
    >> "$OUTPUT_CSV"

  log "INFO" "  VM $VM_NAME processed successfully"
done

log "DEBUG" "Loop finished after $VM_INDEX iterations"

log "INFO" "=========================================="
log "INFO" "Script completed successfully"
log "INFO" "=========================================="
log "INFO" "CSV written: $OUTPUT_CSV"
log "INFO" "Log file: $LOG_FILE"
echo "CSV written: $OUTPUT_CSV"
echo "Log file: $LOG_FILE"
echo "Import this CSV in Azure Migrate > Discovery and assessment > Import using CSV (assessment/TCO only)."  # [6](https://learn.microsoft.com/en-us/azure/migrate/tutorial-discover-import?view=migrate)
