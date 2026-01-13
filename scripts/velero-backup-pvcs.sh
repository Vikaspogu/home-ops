#!/bin/bash
#
# Velero PVC Backup Script
# Backs up all PVCs with their data using File System Backup (Kopia)
#
set -euo pipefail

# Configuration
VELERO_NAMESPACE="${VELERO_NAMESPACE:-storage}"
BACKUP_TTL="${BACKUP_TTL:-720h}"  # 30 days default
BACKUP_STORAGE_LOCATION="${BACKUP_STORAGE_LOCATION:-default}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -a, --all                    Backup all PVCs in ALL namespaces"
    echo "  -n, --namespace NAMESPACE    Backup PVCs from specific namespace"
    echo "  -b, --backup-name NAME       Custom backup name (default: auto-generated)"
    echo "  -t, --ttl DURATION           Backup TTL (default: 720h / 30 days)"
    echo "  -l, --selector LABEL         Label selector for pods (e.g., app=postgres)"
    echo "  -e, --exclude-ns NAMESPACES  Comma-separated namespaces to exclude"
    echo "  -w, --wait                   Wait for backup to complete"
    echo "  --list-pvcs                  List all PVCs and exit"
    echo "  -h, --help                   Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 -a -w                                    # Backup ALL PVCs in all namespaces"
    echo "  $0 -a -e kube-system,storage -w            # Backup all except kube-system,storage"
    echo "  $0 -n default -w                           # Backup all PVCs in default namespace"
    echo "  $0 -n default -l app=postgres -w           # Backup PVCs for pods with label"
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

list_pvcs() {
    log_info "PVCs across all namespaces:"
    echo ""
    kubectl get pvc --all-namespaces -o wide
    echo ""
    log_info "Total PVCs: $(kubectl get pvc --all-namespaces --no-headers | wc -l)"
}

# Parse arguments
BACKUP_ALL=""
NAMESPACE=""
BACKUP_NAME=""
LABEL_SELECTOR=""
EXCLUDE_NAMESPACES=""
WAIT_FLAG=""
LIST_PVCS=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -a|--all)
            BACKUP_ALL="yes"
            shift
            ;;
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -b|--backup-name)
            BACKUP_NAME="$2"
            shift 2
            ;;
        -t|--ttl)
            BACKUP_TTL="$2"
            shift 2
            ;;
        -l|--selector)
            LABEL_SELECTOR="$2"
            shift 2
            ;;
        -e|--exclude-ns)
            EXCLUDE_NAMESPACES="$2"
            shift 2
            ;;
        -w|--wait)
            WAIT_FLAG="--wait"
            shift
            ;;
        --list-pvcs)
            LIST_PVCS="yes"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Handle list-pvcs
if [[ "$LIST_PVCS" == "yes" ]]; then
    list_pvcs
    exit 0
fi

# Validate arguments
if [[ -z "$BACKUP_ALL" && -z "$NAMESPACE" ]]; then
    log_error "Either -a (all namespaces) or -n (specific namespace) is required"
    usage
    exit 1
fi

if [[ -n "$BACKUP_ALL" && -n "$NAMESPACE" ]]; then
    log_error "Cannot use both -a and -n together"
    usage
    exit 1
fi

# Generate backup name if not provided
if [[ -z "$BACKUP_NAME" ]]; then
    TIMESTAMP=$(date +%Y%m%d%H%M%S)
    if [[ -n "$BACKUP_ALL" ]]; then
        BACKUP_NAME="all-namespaces-pvc-backup-${TIMESTAMP}"
    else
        BACKUP_NAME="${NAMESPACE}-pvc-backup-${TIMESTAMP}"
    fi
fi

# Check velero is available
if ! command -v velero &> /dev/null; then
    log_error "velero CLI not found. Please install velero."
    exit 1
fi

# Check velero is running
if ! kubectl get deployment velero -n "$VELERO_NAMESPACE" &> /dev/null; then
    log_error "Velero deployment not found in namespace $VELERO_NAMESPACE"
    exit 1
fi

# Show what will be backed up
log_step "Analyzing PVCs to backup..."
if [[ -n "$BACKUP_ALL" ]]; then
    if [[ -n "$EXCLUDE_NAMESPACES" ]]; then
        log_info "Backing up all PVCs EXCEPT namespaces: $EXCLUDE_NAMESPACES"
    else
        log_info "Backing up ALL PVCs in all namespaces"
    fi
    echo ""
    kubectl get pvc --all-namespaces --no-headers | while read ns name _; do
        skip=false
        if [[ -n "$EXCLUDE_NAMESPACES" ]]; then
            for excl in $(echo "$EXCLUDE_NAMESPACES" | tr ',' ' '); do
                if [[ "$ns" == "$excl" ]]; then
                    skip=true
                    break
                fi
            done
        fi
        if [[ "$skip" == "false" ]]; then
            echo "  - $ns/$name"
        fi
    done
else
    log_info "Backing up PVCs in namespace: $NAMESPACE"
    kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | while read name _; do
        echo "  - $NAMESPACE/$name"
    done || log_warn "No PVCs found in namespace $NAMESPACE"
fi
echo ""

# Build velero backup command
VELERO_CMD="velero backup create $BACKUP_NAME"
VELERO_CMD="$VELERO_CMD --ttl $BACKUP_TTL"
VELERO_CMD="$VELERO_CMD --storage-location $BACKUP_STORAGE_LOCATION"
VELERO_CMD="$VELERO_CMD --default-volumes-to-fs-backup=true"
VELERO_CMD="$VELERO_CMD -n $VELERO_NAMESPACE"

if [[ -n "$BACKUP_ALL" ]]; then
    VELERO_CMD="$VELERO_CMD --include-namespaces '*'"
    if [[ -n "$EXCLUDE_NAMESPACES" ]]; then
        VELERO_CMD="$VELERO_CMD --exclude-namespaces $EXCLUDE_NAMESPACES"
    fi
else
    VELERO_CMD="$VELERO_CMD --include-namespaces $NAMESPACE"
fi

if [[ -n "$LABEL_SELECTOR" ]]; then
    VELERO_CMD="$VELERO_CMD --selector $LABEL_SELECTOR"
fi

if [[ -n "$WAIT_FLAG" ]]; then
    VELERO_CMD="$VELERO_CMD $WAIT_FLAG"
fi

# Show configuration
log_info "Backup Configuration:"
echo "  Name: $BACKUP_NAME"
echo "  TTL: $BACKUP_TTL"
echo "  Storage Location: $BACKUP_STORAGE_LOCATION"
echo "  FSB Enabled: true"
[[ -n "$LABEL_SELECTOR" ]] && echo "  Label Selector: $LABEL_SELECTOR"
[[ -n "$EXCLUDE_NAMESPACES" ]] && echo "  Excluded Namespaces: $EXCLUDE_NAMESPACES"
echo ""

# Confirm
read -p "Proceed with backup? (Y/n): " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Nn]$ ]]; then
    log_info "Aborted."
    exit 0
fi

# Run backup
log_step "Creating backup..."
log_info "Running: $VELERO_CMD"
eval "$VELERO_CMD"

# Show result
if [[ -n "$WAIT_FLAG" ]]; then
    echo ""
    log_info "Backup completed. Volume backup details:"
    velero backup describe "$BACKUP_NAME" -n "$VELERO_NAMESPACE" --details | grep -A20 "Pod Volume Backups" || true
else
    echo ""
    log_info "Backup started. Monitor with:"
    echo "  velero backup describe $BACKUP_NAME -n $VELERO_NAMESPACE --details"
    echo "  velero backup logs $BACKUP_NAME -n $VELERO_NAMESPACE"
fi

echo ""
log_info "To restore this backup later:"
echo "  ./velero-restore-pvcs.sh -b $BACKUP_NAME -a -w    # Restore all namespaces"
echo "  ./velero-restore-pvcs.sh -b $BACKUP_NAME -n <ns> -w  # Restore specific namespace"
