#!/bin/bash
#
# Velero PVC Restore Script
# Restores PVCs with their data from a Velero backup
#
# IMPORTANT: For FSB (File System Backup) data restore to work:
# - StatefulSets/Deployments must be deleted so Velero can recreate them
# - PVCs must be deleted so Velero can recreate them with data
# - Pods must be created by Velero for volume data to be restored into
#
set -euo pipefail

# Configuration
VELERO_NAMESPACE="${VELERO_NAMESPACE:-storage}"

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
    echo "  -b, --backup-name NAME       Backup name to restore from (required)"
    echo "  -a, --all                    Restore ALL namespaces from backup"
    echo "  -n, --namespace NAMESPACE    Restore specific namespace only"
    echo "  -p, --pvc PVC_NAME           Restore specific PVC only (requires -n)"
    echo "  -r, --restore-name NAME      Custom restore name (default: auto-generated)"
    echo "  -d, --delete-existing        Auto-delete existing resources (no prompt)"
    echo "  -w, --wait                   Wait for restore to complete"
    echo "  -l, --list-backups           List available backups"
    echo "  --dry-run                    Show what would be deleted, don't execute"
    echo "  -h, --help                   Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 -l                                        # List available backups"
    echo "  $0 -b my-backup -a -d -w                    # Restore all namespaces"
    echo "  $0 -b my-backup -n default -d -w           # Restore default namespace"
    echo "  $0 -b my-backup -n default -p data-pg-0 -w # Restore specific PVC"
    echo "  $0 -b my-backup -n default --dry-run       # Preview what would be deleted"
    echo ""
    echo "IMPORTANT: Existing StatefulSets/Deployments and PVCs must be deleted"
    echo "for Velero FSB to restore volume data. This script handles that automatically."
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

list_backups() {
    log_info "Available backups:"
    echo ""
    velero backup get -n "$VELERO_NAMESPACE"
    echo ""
    log_info "To see backup contents:"
    echo "  velero backup describe <backup-name> -n $VELERO_NAMESPACE --details"
}

show_backup_contents() {
    local backup_name=$1
    log_info "Backup '$backup_name' contains:"
    echo ""
    
    # Get namespaces in backup
    local namespaces=$(velero backup describe "$backup_name" -n "$VELERO_NAMESPACE" --details 2>/dev/null | \
        grep -E "v1/PersistentVolumeClaim:" -A100 | grep -E "^\s+- " | \
        awk -F'/' '{print $1}' | sed 's/^[[:space:]]*- //' | sort -u)
    
    if [[ -n "$namespaces" ]]; then
        echo "Namespaces with PVCs:"
        for ns in $namespaces; do
            echo "  - $ns"
            velero backup describe "$backup_name" -n "$VELERO_NAMESPACE" --details 2>/dev/null | \
                grep -E "v1/PersistentVolumeClaim:" -A100 | grep "$ns/" | sed 's/^/      /' | head -10
        done
    fi
    
    echo ""
    echo "Pod Volume Backups (FSB data):"
    velero backup describe "$backup_name" -n "$VELERO_NAMESPACE" --details 2>/dev/null | \
        grep -A20 "Pod Volume Backups" | head -25
}

find_pod_owner() {
    # Given a pod, find its top-level owner (StatefulSet, Deployment, DaemonSet, Job, etc.)
    local namespace=$1
    local pod_name=$2
    
    local owner_info=$(kubectl get pod "$pod_name" -n "$namespace" -o json 2>/dev/null | \
        jq -r '.metadata.ownerReferences[]? | "\(.kind)|\(.name)"' 2>/dev/null | head -1)
    
    if [[ -z "$owner_info" ]]; then
        echo "Pod|$pod_name"
        return
    fi
    
    local owner_kind=$(echo "$owner_info" | cut -d'|' -f1)
    local owner_name=$(echo "$owner_info" | cut -d'|' -f2)
    
    # If owned by ReplicaSet, find the Deployment
    if [[ "$owner_kind" == "ReplicaSet" ]]; then
        local deploy=$(kubectl get replicaset "$owner_name" -n "$namespace" -o json 2>/dev/null | \
            jq -r '.metadata.ownerReferences[]? | select(.kind == "Deployment") | .name' 2>/dev/null | head -1)
        if [[ -n "$deploy" ]]; then
            echo "Deployment|$deploy"
            return
        fi
    fi
    
    echo "$owner_kind|$owner_name"
}

find_resources_using_pvc() {
    local namespace=$1
    local pvc_name=$2
    
    # Find all pods using this PVC
    local pods=$(kubectl get pods -n "$namespace" -o json 2>/dev/null | \
        jq -r ".items[] | select(.spec.volumes[]?.persistentVolumeClaim.claimName == \"$pvc_name\") | .metadata.name" 2>/dev/null)
    
    local statefulsets=""
    local deployments=""
    local daemonsets=""
    local jobs=""
    local standalone_pods=""
    
    for pod in $pods; do
        local owner=$(find_pod_owner "$namespace" "$pod")
        local kind=$(echo "$owner" | cut -d'|' -f1)
        local name=$(echo "$owner" | cut -d'|' -f2)
        
        case "$kind" in
            StatefulSet)
                if [[ ! " $statefulsets " =~ " $name " ]]; then
                    statefulsets="$statefulsets $name"
                fi
                ;;
            Deployment)
                if [[ ! " $deployments " =~ " $name " ]]; then
                    deployments="$deployments $name"
                fi
                ;;
            DaemonSet)
                if [[ ! " $daemonsets " =~ " $name " ]]; then
                    daemonsets="$daemonsets $name"
                fi
                ;;
            Job)
                if [[ ! " $jobs " =~ " $name " ]]; then
                    jobs="$jobs $name"
                fi
                ;;
            Pod)
                if [[ ! " $standalone_pods " =~ " $name " ]]; then
                    standalone_pods="$standalone_pods $name"
                fi
                ;;
        esac
    done
    
    # Also check StatefulSet volumeClaimTemplates (for PVCs created by STS)
    # PVC name pattern: <volumeClaimTemplate-name>-<statefulset-name>-<ordinal>
    local sts_from_template=$(kubectl get statefulsets -n "$namespace" -o json 2>/dev/null | \
        jq -r ".items[] | select(.spec.volumeClaimTemplates[]?.metadata.name as \$tmpl | \"$pvc_name\" | test(\"^\(\$tmpl)-.*-[0-9]+$\")) | .metadata.name" 2>/dev/null | head -1)
    
    if [[ -n "$sts_from_template" && ! " $statefulsets " =~ " $sts_from_template " ]]; then
        statefulsets="$statefulsets $sts_from_template"
    fi
    
    echo "$(echo $statefulsets | xargs)|$(echo $deployments | xargs)|$(echo $daemonsets | xargs)|$(echo $jobs | xargs)|$(echo $standalone_pods | xargs)"
}

force_delete_pvc() {
    local namespace=$1
    local pvc_name=$2
    
    # Check if PVC exists
    if ! kubectl get pvc "$pvc_name" -n "$namespace" &>/dev/null; then
        return 0
    fi
    
    # Get associated PV name before deleting PVC
    local pv_name=$(kubectl get pvc "$pvc_name" -n "$namespace" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)
    
    # Try normal delete first with short timeout
    log_info "  Deleting PVC: $pvc_name"
    if kubectl delete pvc "$pvc_name" -n "$namespace" --ignore-not-found --wait=true --timeout=30s 2>/dev/null; then
        return 0
    fi
    
    # If stuck, remove finalizers
    log_warn "  PVC deletion stuck, removing finalizers..."
    kubectl patch pvc "$pvc_name" -n "$namespace" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    
    # Force delete
    kubectl delete pvc "$pvc_name" -n "$namespace" --ignore-not-found --force --grace-period=0 2>/dev/null || true
    
    # Wait briefly for PVC to be gone
    sleep 2
    
    # If PV exists and is stuck, clean it up too
    if [[ -n "$pv_name" ]] && kubectl get pv "$pv_name" &>/dev/null; then
        local pv_status=$(kubectl get pv "$pv_name" -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [[ "$pv_status" == "Released" || "$pv_status" == "Failed" ]]; then
            log_warn "  Cleaning up PV: $pv_name (status: $pv_status)"
            kubectl patch pv "$pv_name" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
            kubectl delete pv "$pv_name" --ignore-not-found --force --grace-period=0 2>/dev/null || true
        fi
    fi
    
    # Verify PVC is gone
    if kubectl get pvc "$pvc_name" -n "$namespace" &>/dev/null; then
        log_error "  Failed to delete PVC: $pvc_name"
        return 1
    fi
    
    return 0
}

wait_for_pods_using_pvc() {
    local namespace=$1
    local pvc_name=$2
    local timeout=${3:-60}
    
    log_info "  Waiting for pods using PVC '$pvc_name' to terminate..."
    local end_time=$((SECONDS + timeout))
    
    while [[ $SECONDS -lt $end_time ]]; do
        local pods=$(kubectl get pods -n "$namespace" -o json 2>/dev/null | \
            jq -r ".items[] | select(.spec.volumes[]?.persistentVolumeClaim.claimName == \"$pvc_name\") | .metadata.name" 2>/dev/null)
        
        if [[ -z "$pods" ]]; then
            log_info "  All pods using PVC terminated"
            return 0
        fi
        
        sleep 2
    done
    
    log_warn "  Timeout waiting for pods to terminate, will force delete"
    return 1
}

delete_resources_for_pvc() {
    local namespace=$1
    local pvc_name=$2
    local dry_run=$3
    
    local resources=$(find_resources_using_pvc "$namespace" "$pvc_name")
    local statefulsets=$(echo "$resources" | cut -d'|' -f1)
    local deployments=$(echo "$resources" | cut -d'|' -f2)
    local daemonsets=$(echo "$resources" | cut -d'|' -f3)
    local jobs=$(echo "$resources" | cut -d'|' -f4)
    local standalone_pods=$(echo "$resources" | cut -d'|' -f5)
    
    if [[ "$dry_run" == "yes" ]]; then
        for sts in $statefulsets; do
            echo "    Would delete StatefulSet: $sts"
        done
        for deploy in $deployments; do
            echo "    Would delete Deployment: $deploy"
        done
        for ds in $daemonsets; do
            echo "    Would delete DaemonSet: $ds"
        done
        for job in $jobs; do
            echo "    Would delete Job: $job"
        done
        for pod in $standalone_pods; do
            echo "    Would delete Pod: $pod"
        done
        echo "    Would delete PVC: $pvc_name"
        echo "    Would delete associated PV (if stuck)"
    else
        # 1. Delete StatefulSets first (cascading delete will remove pods)
        for sts in $statefulsets; do
            log_info "  Deleting StatefulSet: $sts"
            kubectl delete statefulset "$sts" -n "$namespace" --ignore-not-found --cascade=foreground --timeout=120s 2>/dev/null || \
                kubectl delete statefulset "$sts" -n "$namespace" --ignore-not-found --force --grace-period=0 2>/dev/null || true
        done
        
        # 2. Delete Deployments (cascading delete will remove ReplicaSets and pods)
        for deploy in $deployments; do
            log_info "  Deleting Deployment: $deploy"
            kubectl delete deployment "$deploy" -n "$namespace" --ignore-not-found --cascade=foreground --timeout=120s 2>/dev/null || \
                kubectl delete deployment "$deploy" -n "$namespace" --ignore-not-found --force --grace-period=0 2>/dev/null || true
        done
        
        # 3. Delete DaemonSets
        for ds in $daemonsets; do
            log_info "  Deleting DaemonSet: $ds"
            kubectl delete daemonset "$ds" -n "$namespace" --ignore-not-found --cascade=foreground --timeout=120s 2>/dev/null || \
                kubectl delete daemonset "$ds" -n "$namespace" --ignore-not-found --force --grace-period=0 2>/dev/null || true
        done
        
        # 4. Delete Jobs
        for job in $jobs; do
            log_info "  Deleting Job: $job"
            kubectl delete job "$job" -n "$namespace" --ignore-not-found --cascade=foreground --timeout=60s 2>/dev/null || \
                kubectl delete job "$job" -n "$namespace" --ignore-not-found --force --grace-period=0 2>/dev/null || true
        done
        
        # 5. Delete standalone pods
        for pod in $standalone_pods; do
            log_info "  Deleting standalone Pod: $pod"
            kubectl delete pod "$pod" -n "$namespace" --ignore-not-found --grace-period=30 --timeout=60s 2>/dev/null || \
                kubectl delete pod "$pod" -n "$namespace" --ignore-not-found --force --grace-period=0 2>/dev/null || true
        done
        
        # 6. Wait for all pods using the PVC to terminate
        wait_for_pods_using_pvc "$namespace" "$pvc_name" 60 || true
        
        # 7. Force delete any remaining stuck pods
        local remaining_pods=$(kubectl get pods -n "$namespace" -o json 2>/dev/null | \
            jq -r ".items[] | select(.spec.volumes[]?.persistentVolumeClaim.claimName == \"$pvc_name\") | .metadata.name" 2>/dev/null)
        
        for pod in $remaining_pods; do
            log_warn "  Force deleting stuck Pod: $pod"
            kubectl patch pod "$pod" -n "$namespace" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
            kubectl delete pod "$pod" -n "$namespace" --ignore-not-found --force --grace-period=0 2>/dev/null || true
        done
        
        # Brief pause to ensure pod termination
        sleep 2
        
        # 8. Finally delete PVC with force handling
        force_delete_pvc "$namespace" "$pvc_name"
    fi
}

# Parse arguments
BACKUP_NAME=""
RESTORE_ALL=""
NAMESPACE=""
PVC_NAME=""
RESTORE_NAME=""
DELETE_EXISTING=""
WAIT_FLAG=""
DRY_RUN=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -b|--backup-name)
            BACKUP_NAME="$2"
            shift 2
            ;;
        -a|--all)
            RESTORE_ALL="yes"
            shift
            ;;
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -p|--pvc)
            PVC_NAME="$2"
            shift 2
            ;;
        -r|--restore-name)
            RESTORE_NAME="$2"
            shift 2
            ;;
        -d|--delete-existing)
            DELETE_EXISTING="yes"
            shift
            ;;
        -w|--wait)
            WAIT_FLAG="--wait"
            shift
            ;;
        -l|--list-backups)
            list_backups
            exit 0
            ;;
        --dry-run)
            DRY_RUN="yes"
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

# Validate required arguments
if [[ -z "$BACKUP_NAME" ]]; then
    log_error "Backup name is required (-b)"
    usage
    exit 1
fi

if [[ -z "$RESTORE_ALL" && -z "$NAMESPACE" ]]; then
    log_error "Either -a (all namespaces) or -n (specific namespace) is required"
    usage
    exit 1
fi

if [[ -n "$PVC_NAME" && -z "$NAMESPACE" ]]; then
    log_error "Namespace (-n) is required when specifying PVC (-p)"
    usage
    exit 1
fi

# Check velero is available
if ! command -v velero &> /dev/null; then
    log_error "velero CLI not found. Please install velero."
    exit 1
fi

# Verify backup exists
if ! velero backup get "$BACKUP_NAME" -n "$VELERO_NAMESPACE" &> /dev/null; then
    log_error "Backup '$BACKUP_NAME' not found"
    list_backups
    exit 1
fi

# Generate restore name if not provided
if [[ -z "$RESTORE_NAME" ]]; then
    TIMESTAMP=$(date +%Y%m%d%H%M%S)
    RESTORE_NAME="restore-${TIMESTAMP}"
fi

# Show backup info
log_step "Backup Information"
show_backup_contents "$BACKUP_NAME"
echo ""

# Determine what to restore
if [[ -n "$RESTORE_ALL" ]]; then
    log_step "Preparing to restore ALL namespaces from backup"
    # Get namespaces from backup that have PVCs
    NAMESPACES_TO_RESTORE=$(velero backup describe "$BACKUP_NAME" -n "$VELERO_NAMESPACE" --details 2>/dev/null | \
        grep -E "v1/PersistentVolumeClaim:" -A100 | grep -E "^\s+- " | \
        awk -F'/' '{print $1}' | sed 's/^[[:space:]]*- //' | sort -u)
else
    NAMESPACES_TO_RESTORE="$NAMESPACE"
fi

# Find and list resources to delete
log_step "Resources that need to be deleted for restore:"
echo ""

RESOURCES_TO_DELETE=""
for ns in $NAMESPACES_TO_RESTORE; do
    if [[ -n "$PVC_NAME" ]]; then
        # Specific PVC
        pvcs="$PVC_NAME"
    else
        # All PVCs in namespace
        pvcs=$(kubectl get pvc -n "$ns" --no-headers 2>/dev/null | awk '{print $1}' || true)
    fi
    
    if [[ -n "$pvcs" ]]; then
        echo "Namespace: $ns"
        for pvc in $pvcs; do
            RESOURCES_TO_DELETE="yes"
            if [[ "$DRY_RUN" == "yes" ]]; then
                delete_resources_for_pvc "$ns" "$pvc" "yes"
            else
                echo "  PVC: $pvc"
                resources=$(find_resources_using_pvc "$ns" "$pvc")
                statefulsets=$(echo "$resources" | cut -d'|' -f1)
                deployments=$(echo "$resources" | cut -d'|' -f2)
                daemonsets=$(echo "$resources" | cut -d'|' -f3)
                jobs=$(echo "$resources" | cut -d'|' -f4)
                standalone_pods=$(echo "$resources" | cut -d'|' -f5)
                
                for sts in $statefulsets; do
                    echo "    -> StatefulSet: $sts"
                done
                for deploy in $deployments; do
                    echo "    -> Deployment: $deploy"
                done
                for ds in $daemonsets; do
                    echo "    -> DaemonSet: $ds"
                done
                for job in $jobs; do
                    echo "    -> Job: $job"
                done
                for pod in $standalone_pods; do
                    echo "    -> Pod: $pod"
                done
            fi
        done
        echo ""
    fi
done

if [[ "$DRY_RUN" == "yes" ]]; then
    log_info "Dry run complete. No changes made."
    exit 0
fi

if [[ -z "$RESOURCES_TO_DELETE" ]]; then
    log_info "No existing resources found that need deletion."
fi

# Confirm deletion
if [[ -n "$RESOURCES_TO_DELETE" && "$DELETE_EXISTING" != "yes" ]]; then
    echo ""
    echo -e "${YELLOW}WARNING: The above resources must be deleted for volume data restore to work.${NC}"
    echo -e "${YELLOW}StatefulSets/Deployments/DaemonSets/Jobs will be recreated by Velero with restored data.${NC}"
    echo ""
    read -p "Delete resources and proceed with restore? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Aborted."
        exit 0
    fi
fi

# Delete resources
if [[ -n "$RESOURCES_TO_DELETE" ]]; then
    log_step "Deleting existing resources..."
    for ns in $NAMESPACES_TO_RESTORE; do
        if [[ -n "$PVC_NAME" ]]; then
            pvcs="$PVC_NAME"
        else
            pvcs=$(kubectl get pvc -n "$ns" --no-headers 2>/dev/null | awk '{print $1}' || true)
        fi
        
        for pvc in $pvcs; do
            delete_resources_for_pvc "$ns" "$pvc" "no"
        done
    done
    
    log_info "Waiting for resources to be fully deleted..."
    sleep 5
fi

# Clean up old restores
log_step "Cleaning up old restore objects..."
kubectl delete restore -n "$VELERO_NAMESPACE" -l velero.io/backup-name="$BACKUP_NAME" --ignore-not-found 2>/dev/null || true

# Build restore command
log_step "Creating restore: $RESTORE_NAME"

VELERO_CMD="velero restore create $RESTORE_NAME"
VELERO_CMD="$VELERO_CMD --from-backup $BACKUP_NAME"
VELERO_CMD="$VELERO_CMD --restore-volumes=true"
VELERO_CMD="$VELERO_CMD -n $VELERO_NAMESPACE"

if [[ -n "$RESTORE_ALL" ]]; then
    # Restore all namespaces that were in the backup
    VELERO_CMD="$VELERO_CMD --include-namespaces '*'"
elif [[ -n "$NAMESPACE" ]]; then
    VELERO_CMD="$VELERO_CMD --include-namespaces $NAMESPACE"
fi

if [[ -n "$WAIT_FLAG" ]]; then
    VELERO_CMD="$VELERO_CMD $WAIT_FLAG"
fi

# Run restore
log_info "Running: $VELERO_CMD"
echo ""
eval "$VELERO_CMD"

# Show results
echo ""
if [[ -n "$WAIT_FLAG" ]]; then
    log_step "Restore Results"
    
    # Show restore status
    velero restore describe "$RESTORE_NAME" -n "$VELERO_NAMESPACE" | grep -E "Phase:|Items restored:|Warnings:|Errors:" | head -10
    echo ""
    
    # Check for PodVolumeRestores
    log_info "Volume Data Restores:"
    kubectl get podvolumerestores -n "$VELERO_NAMESPACE" -l velero.io/restore-name="$RESTORE_NAME" 2>/dev/null || echo "  None found"
    echo ""
    
    # Show restored resources
    log_info "Restored PVCs:"
    for ns in $NAMESPACES_TO_RESTORE; do
        kubectl get pvc -n "$ns" 2>/dev/null | head -10 || true
    done
    echo ""
    
    log_info "Restored Pods:"
    for ns in $NAMESPACES_TO_RESTORE; do
        kubectl get pods -n "$ns" 2>/dev/null | head -10 || true
    done
else
    log_info "Restore started. Monitor with:"
    echo "  velero restore describe $RESTORE_NAME -n $VELERO_NAMESPACE"
    echo "  kubectl get podvolumerestores -n $VELERO_NAMESPACE -w"
fi

echo ""
log_info "Done!"
