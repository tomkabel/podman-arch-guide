#!/usr/bin/env bash
#===============================================================================
# backup.sh - Enterprise Podman Backup Automation Script
#===============================================================================
# Description: Automates container volume backups with consistent snapshots,
#              configuration export, encrypted storage, retention policies,
#              and backup verification through test restores.
# Author: DevOps Team
# Version: 1.0.0
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "$0")"
readonly VERSION="1.0.0"
readonly LOG_DIR="${LOG_DIR:-/var/log/podman-backup}"
readonly LOG_FILE="${LOG_DIR}/backup-$(date +%Y%m%d-%H%M%S).log"
readonly LOCK_FILE="/tmp/${SCRIPT_NAME}.lock"

#-------------------------------------------------------------------------------
# Backup Configuration
#-------------------------------------------------------------------------------
BACKUP_ROOT="${BACKUP_ROOT:-/backup/podman}"
PROJECT_NAME="${PROJECT_NAME:-}"
BACKUP_TYPE="${BACKUP_TYPE:-full}"  # full, volumes, config, images
RETENTION_DAYS="${RETENTION_DAYS:-30}"
RETENTION_COUNT="${RETENTION_COUNT:-10}"
ENCRYPT_BACKUP="${ENCRYPT_BACKUP:-false}"
GPG_RECIPIENT="${GPG_RECIPIENT:-}"
COMPRESS_LEVEL="${COMPRESS_LEVEL:-6}"  # 1-9
VERIFY_BACKUP="${VERIFY_BACKUP:-true}"
DRY_RUN="${DRY_RUN:-false}"
EXCLUDE_VOLUMES="${EXCLUDE_VOLUMES:-}"

#-------------------------------------------------------------------------------
# Colors for terminal output
#-------------------------------------------------------------------------------
declare -r RED='\033[0;31m'
declare -r GREEN='\033[0;32m'
declare -r YELLOW='\033[1;33m'
declare -r BLUE='\033[0;34m'
declare -r CYAN='\033[0;36m'
declare -r NC='\033[0m'

#-------------------------------------------------------------------------------
# Logging Functions
#-------------------------------------------------------------------------------
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    mkdir -p "$LOG_DIR"
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    case "$level" in
        ERROR)   echo -e "${RED}[$timestamp] [ERROR] $message${NC}" >&2 ;;
        WARN)    echo -e "${YELLOW}[$timestamp] [WARN] $message${NC}" ;;
        SUCCESS) echo -e "${GREEN}[$timestamp] [SUCCESS] $message${NC}" ;;
        INFO)    echo -e "${BLUE}[$timestamp] [INFO] $message${NC}" ;;
        BACKUP)  echo -e "${CYAN}[$timestamp] [BACKUP] $message${NC}" ;;
        *)       echo "[$timestamp] [$level] $message" ;;
    esac
}

log_info()   { log "INFO" "$*"; }
log_warn()   { log "WARN" "$*"; }
log_error()  { log "ERROR" "$*"; }
log_success(){ log "SUCCESS" "$*"; }
log_backup() { log "BACKUP" "$*"; }

#-------------------------------------------------------------------------------
# Error Handling
#-------------------------------------------------------------------------------
die() {
    log_error "$@"
    cleanup
    exit 1
}

cleanup() {
    log_info "Performing cleanup..."
    
    # Remove temporary files
    if [[ -n "${TEMP_DIR:-}" ]] && [[ -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
    
    if [[ -f "$LOCK_FILE" ]]; then
        rm -f "$LOCK_FILE"
    fi
}

trap_cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Backup failed with exit code $exit_code"
    fi
    cleanup
    exit $exit_code
}

trap trap_cleanup EXIT INT TERM

#-------------------------------------------------------------------------------
# Lock Management
#-------------------------------------------------------------------------------
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null) || true
        if ps -p "$pid" > /dev/null 2>&1; then
            die "Another backup is in progress (PID: ${pid})"
        else
            log_warn "Removing stale lock file"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    log_info "Acquired backup lock"
}

#-------------------------------------------------------------------------------
# Backup Path Helpers
#-------------------------------------------------------------------------------
get_backup_path() {
    local backup_type="$1"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    
    echo "${BACKUP_ROOT}/${PROJECT_NAME:-all}/${backup_type}/${timestamp}"
}

#-------------------------------------------------------------------------------
# Volume Backup
#-------------------------------------------------------------------------------
backup_volumes() {
    log_backup "Starting volume backup..."
    
    local backup_path
    backup_path=$(get_backup_path "volumes")
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would backup volumes to ${backup_path}"
        return 0
    fi
    
    mkdir -p "$backup_path"
    
    # Get list of volumes
    local volumes
    if [[ -n "$PROJECT_NAME" ]]; then
        volumes=$(podman volume ls --filter "label=project=${PROJECT_NAME}" -q 2>/dev/null || true)
    else
        volumes=$(podman volume ls -q 2>/dev/null || true)
    fi
    
    if [[ -z "$volumes" ]]; then
        log_warn "No volumes found to backup"
        return 0
    fi
    
    local backed_up=0
    local failed=0
    
    while IFS= read -r volume; do
        [[ -z "$volume" ]] && continue
        
        # Check if excluded
        if [[ -n "$EXCLUDE_VOLUMES" ]] && echo "$EXCLUDE_VOLUMES" | grep -qw "$volume"; then
            log_info "Skipping excluded volume: $volume"
            continue
        fi
        
        log_backup "Backing up volume: $volume"
        
        local volume_path
        volume_path=$(podman volume inspect "$volume" --format '{{.Mountpoint}}' 2>/dev/null || true)
        
        if [[ -z "$volume_path" ]] || [[ ! -d "$volume_path" ]]; then
            log_warn "Volume path not found: $volume"
            ((failed++))
            continue
        fi
        
        # Create consistent snapshot using tar
        local backup_file="${backup_path}/${volume}.tar.gz"
        
        # Use tar with preserve permissions and acl/xattr if available
        if tar czf "$backup_file" -C "$(dirname "$volume_path")" "$(basename "$volume_path")" 2>/dev/null; then
            log_success "Volume backup created: $backup_file"
            
            # Calculate checksum
            sha256sum "$backup_file" > "${backup_file}.sha256"
            
            # Encrypt if requested
            if [[ "$ENCRYPT_BACKUP" == "true" ]] && [[ -n "$GPG_RECIPIENT" ]]; then
                encrypt_backup "$backup_file"
            fi
            
            ((backed_up++))
        else
            log_error "Failed to backup volume: $volume"
            ((failed++))
        fi
    done <<< "$volumes"
    
    log_backup "Volume backup complete: ${backed_up} succeeded, ${failed} failed"
    
    if [[ $failed -gt 0 ]]; then
        return 1
    fi
    
    return 0
}

#-------------------------------------------------------------------------------
# Container Configuration Backup
#-------------------------------------------------------------------------------
backup_config() {
    log_backup "Starting configuration backup..."
    
    local backup_path
    backup_path=$(get_backup_path "config")
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would backup configuration to ${backup_path}"
        return 0
    fi
    
    mkdir -p "$backup_path"
    
    # Get containers to backup
    local containers
    if [[ -n "$PROJECT_NAME" ]]; then
        containers=$(podman ps -a --filter "label=project=${PROJECT_NAME}" --format '{{.Names}}' 2>/dev/null || true)
    else
        containers=$(podman ps -a --format '{{.Names}}' 2>/dev/null || true)
    fi
    
    if [[ -z "$containers" ]]; then
        log_warn "No containers found for config backup"
        return 0
    fi
    
    # Backup container configurations
    local config_file="${backup_path}/containers.json"
    local container_configs=()
    
    while IFS= read -r container; do
        [[ -z "$container" ]] && continue
        
        log_backup "Exporting config for: $container"
        
        local config
        config=$(podman inspect "$container" 2>/dev/null || echo "[]")
        container_configs+=("$config")
    done <<< "$containers"
    
    # Save all configs as JSON array
    printf '%s\n' "${container_configs[@]}" | jq -s '.' > "$config_file"
    
    # Backup compose files if they exist
    if [[ -n "$PROJECT_NAME" ]]; then
        local compose_files
        compose_files=$(find / -name "docker-compose*.yml" -o -name "podman-compose*.yml" 2>/dev/null | head -20 || true)
        
        while IFS= read -r compose_file; do
            [[ -z "$compose_file" ]] && continue
            
            local compose_name
            compose_name=$(basename "$compose_file")
            cp "$compose_file" "${backup_path}/${compose_name}"
            log_info "Backed up compose file: $compose_file"
        done <<< "$compose_files"
    fi
    
    # Backup podman system configuration
    if [[ -d /etc/containers ]]; then
        tar czf "${backup_path}/etc-containers.tar.gz" -C / etc/containers 2>/dev/null || true
    fi
    
    # Backup networks
    podman network ls --format json > "${backup_path}/networks.json" 2>/dev/null || true
    
    log_success "Configuration backup complete: $backup_path"
}

#-------------------------------------------------------------------------------
# Image Registry Backup
#-------------------------------------------------------------------------------
backup_images() {
    log_backup "Starting image backup..."
    
    local backup_path
    backup_path=$(get_backup_path "images")
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would backup images to ${backup_path}"
        return 0
    fi
    
    mkdir -p "$backup_path"
    
    # Get list of images used by containers
    local images
    if [[ -n "$PROJECT_NAME" ]]; then
        images=$(podman ps -a --filter "label=project=${PROJECT_NAME}" --format '{{.Image}}' 2>/dev/null | sort -u || true)
    else
        images=$(podman ps -a --format '{{.Image}}' 2>/dev/null | sort -u || true)
    fi
    
    if [[ -z "$images" ]]; then
        log_warn "No images found to backup"
        return 0
    fi
    
    local backed_up=0
    local failed=0
    
    while IFS= read -r image; do
        [[ -z "$image" ]] && continue
        
        # Skip if already backed up
        local image_hash
        image_hash=$(echo "$image" | sha256sum | cut -d' ' -f1 | cut -c1-12)
        local image_file="${backup_path}/${image_hash}.tar"
        
        if [[ -f "$image_file" ]]; then
            log_info "Image already backed up: $image"
            continue
        fi
        
        log_backup "Backing up image: $image"
        
        if podman save -o "$image_file" "$image" 2>/dev/null; then
            # Compress the image
            gzip -"${COMPRESS_LEVEL}" "$image_file"
            sha256sum "${image_file}.gz" > "${image_file}.gz.sha256"
            log_success "Image backup created: ${image_file}.gz"
            ((backed_up++))
        else
            log_error "Failed to backup image: $image"
            ((failed++))
        fi
    done <<< "$images"
    
    log_backup "Image backup complete: ${backed_up} succeeded, ${failed} failed"
}

#-------------------------------------------------------------------------------
# Encryption
#-------------------------------------------------------------------------------
encrypt_backup() {
    local file="$1"
    
    log_info "Encrypting: $file"
    
    if [[ -z "$GPG_RECIPIENT" ]]; then
        log_warn "No GPG recipient specified, skipping encryption"
        return 0
    fi
    
    if gpg --encrypt --recipient "$GPG_RECIPIENT" --output "${file}.gpg" "$file" 2>/dev/null; then
        rm -f "$file"
        log_success "Encrypted: ${file}.gpg"
    else
        log_error "Encryption failed for: $file"
    fi
}

#-------------------------------------------------------------------------------
# Backup Verification
#-------------------------------------------------------------------------------
verify_backup() {
    log_backup "Verifying backup integrity..."
    
    if [[ "$VERIFY_BACKUP" != "true" ]]; then
        log_info "Backup verification skipped"
        return 0
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would verify backup"
        return 0
    fi
    
    local latest_backup
    latest_backup=$(find "${BACKUP_ROOT}" -name "*.tar.gz" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2- || true)
    
    if [[ -z "$latest_backup" ]]; then
        log_warn "No backups found to verify"
        return 0
    fi
    
    log_info "Verifying backup: $latest_backup"
    
    # Verify checksum
    local checksum_file="${latest_backup}.sha256"
    if [[ -f "$checksum_file" ]]; then
        if sha256sum -c "$checksum_file" > /dev/null 2>&1; then
            log_success "Checksum verified: $latest_backup"
        else
            log_error "Checksum verification failed: $latest_backup"
            return 1
        fi
    fi
    
    # Test archive integrity
    if tar tzf "$latest_backup" > /dev/null 2>&1; then
        log_success "Archive integrity verified: $latest_backup"
    else
        log_error "Archive integrity check failed: $latest_backup"
        return 1
    fi
    
    # Optional: Test restore to temp location
    TEMP_DIR=$(mktemp -d)
    
    if tar xzf "$latest_backup" -C "$TEMP_DIR" > /dev/null 2>&1; then
        log_success "Test restore successful: $latest_backup"
    else
        log_error "Test restore failed: $latest_backup"
        rm -rf "$TEMP_DIR"
        TEMP_DIR=""
        return 1
    fi
    
    # Cleanup temp directory
    rm -rf "$TEMP_DIR"
    TEMP_DIR=""
    
    log_success "Backup verification complete"
}

#-------------------------------------------------------------------------------
# Retention Policy
#-------------------------------------------------------------------------------
apply_retention() {
    log_backup "Applying retention policy..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would apply retention policy"
        return 0
    fi
    
    # Remove backups older than RETENTION_DAYS
    if [[ -n "$RETENTION_DAYS" ]] && [[ "$RETENTION_DAYS" -gt 0 ]]; then
        log_info "Removing backups older than ${RETENTION_DAYS} days..."
        
        find "${BACKUP_ROOT}" -type f -mtime +${RETENTION_DAYS} -delete 2>/dev/null || true
        find "${BACKUP_ROOT}" -type d -empty -delete 2>/dev/null || true
    fi
    
    # Keep only RETENTION_COUNT most recent backups per type
    if [[ -n "$RETENTION_COUNT" ]] && [[ "$RETENTION_COUNT" -gt 0 ]]; then
        log_info "Keeping only ${RETENTION_COUNT} most recent backups per type..."
        
        for backup_type in volumes config images; do
            local type_path="${BACKUP_ROOT}/${PROJECT_NAME:-all}/${backup_type}"
            
            if [[ -d "$type_path" ]]; then
                # List directories sorted by time, skip the most recent RETENTION_COUNT
                find "$type_path" -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | \
                    sort -rn | \
                    tail -n +$((RETENTION_COUNT + 1)) | \
                    cut -d' ' -f2- | \
                    xargs -r rm -rf 2>/dev/null || true
            fi
        done
    fi
    
    log_success "Retention policy applied"
}

#-------------------------------------------------------------------------------
# Full Backup
#-------------------------------------------------------------------------------
run_full_backup() {
    log_backup "========================================"
    log_backup "Starting Full Backup"
    log_backup "Project: ${PROJECT_NAME:-all}"
    log_backup "Type: ${BACKUP_TYPE}"
    log_backup "========================================"
    
    local failed=0
    
    case "$BACKUP_TYPE" in
        full)
            backup_volumes || ((failed++))
            backup_config || ((failed++))
            backup_images || ((failed++))
            ;;
        volumes)
            backup_volumes || ((failed++))
            ;;
        config)
            backup_config || ((failed++))
            ;;
        images)
            backup_images || ((failed++))
            ;;
        *)
            die "Unknown backup type: $BACKUP_TYPE"
            ;;
    esac
    
    # Verify backup
    verify_backup
    
    # Apply retention policy
    apply_retention
    
    log_backup "========================================"
    if [[ $failed -eq 0 ]]; then
        log_success "Backup completed successfully!"
    else
        log_warn "Backup completed with $failed failures"
    fi
    log_backup "========================================"
    
    # Output summary
    log_info "Backup location: ${BACKUP_ROOT}"
    log_info "Log file: ${LOG_FILE}"
    
    return $failed
}

#-------------------------------------------------------------------------------
# Usage
#-------------------------------------------------------------------------------
usage() {
    cat << EOF
${SCRIPT_NAME} v${VERSION} - Podman Backup Automation

USAGE:
    ${SCRIPT_NAME} [OPTIONS]

OPTIONS:
    -p, --project NAME          Project name (default: all containers)
    -t, --type TYPE             Backup type: full, volumes, config, images (default: full)
    -d, --dest PATH             Backup destination (default: /backup/podman)
    --retention-days N          Delete backups older than N days
    --retention-count N         Keep only N most recent backups
    --encrypt                   Encrypt backups with GPG
    --gpg-recipient EMAIL       GPG recipient for encryption
    --compress N                Compression level 1-9 (default: 6)
    --no-verify                 Skip backup verification
    --exclude-volumes LIST      Comma-separated list of volumes to exclude
    --dry-run                   Show what would be done without executing
    -h, --help                  Show this help message
    -v, --version               Show version information

BACKUP TYPES:
    full       Backup volumes, configuration, and images
    volumes    Backup only container volumes
    config     Backup only container configurations
    images     Backup only container images

RETENTION:
    Use --retention-days to remove old backups by age
    Use --retention-count to limit number of backups kept
    Both can be used together

ENCRYPTION:
    Requires GPG with the recipient's public key imported
    Encrypted files will have .gpg extension

EXAMPLES:
    # Full backup of all containers
    ${SCRIPT_NAME}

    # Backup specific project
    ${SCRIPT_NAME} --project myapp

    # Backup with encryption and retention
    ${SCRIPT_NAME} --encrypt --gpg-recipient admin@example.com --retention-days 30

    # Backup only volumes, excluding temporary data
    ${SCRIPT_NAME} --type volumes --exclude-volumes "temp,cache"

    # Dry run to preview what would be backed up
    ${SCRIPT_NAME} --dry-run

EXIT CODES:
    0   Success
    1   General error
    2   Backup failed
    3   Verification failed

EOF
}

#-------------------------------------------------------------------------------
# Argument Parsing
#-------------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -p|--project)
                PROJECT_NAME="$2"
                shift 2
                ;;
            -t|--type)
                BACKUP_TYPE="$2"
                shift 2
                ;;
            -d|--dest)
                BACKUP_ROOT="$2"
                shift 2
                ;;
            --retention-days)
                RETENTION_DAYS="$2"
                shift 2
                ;;
            --retention-count)
                RETENTION_COUNT="$2"
                shift 2
                ;;
            --encrypt)
                ENCRYPT_BACKUP="true"
                shift
                ;;
            --gpg-recipient)
                GPG_RECIPIENT="$2"
                shift 2
                ;;
            --compress)
                COMPRESS_LEVEL="$2"
                shift 2
                ;;
            --no-verify)
                VERIFY_BACKUP="false"
                shift
                ;;
            --exclude-volumes)
                EXCLUDE_VOLUMES="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -v|--version)
                echo "${SCRIPT_NAME} version ${VERSION}"
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    parse_args "$@"
    acquire_lock
    run_full_backup
    exit $?
}

main "$@"
