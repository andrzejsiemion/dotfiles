#!/bin/zsh
# --- Load Configuration ---
SCRIPT_DIR="${0:A:h}"
ENV_FILE="${SCRIPT_DIR}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: Configuration file not found at $ENV_FILE"
    echo "Please copy .env.example to .env and update with your paths."
    exit 1
fi
source "$ENV_FILE"

# --- Safety & Validation ---
if [[ -z "$BASE_SOURCE" ]] || [[ -z "$BASE_DESTINATION" ]]; then
    echo "Error: BASE_SOURCE and BASE_DESTINATION must be set in .env"
    exit 1
fi

# More robust mount check
if ! mount | grep -q "${BASE_DESTINATION%/}"; then
    # Fallback: check if it's actually a directory on a mounted volume
    if [[ ! -d "$BASE_DESTINATION" ]] || [[ "$(df "$BASE_DESTINATION" | tail -1 | awk '{print $1}')" == "$(df / | tail -1 | awk '{print $1}')" ]]; then
        echo "CRITICAL ERROR: Destination $BASE_DESTINATION is not on a mounted volume."
        echo "Please mount your NAS and try again."
        exit 1
    fi
fi

: ${LOG_DIR:="$HOME/Library/Logs/PhotoSync"}

# --- Pick rsync version ---
if [[ -n "$RSYNC_OVERRIDE" ]]; then
  RSYNC="$RSYNC_OVERRIDE"
elif [[ -x "/opt/homebrew/bin/rsync" ]]; then
  RSYNC="/opt/homebrew/bin/rsync"
elif [[ -x "/usr/local/bin/rsync" ]]; then
  RSYNC="/usr/local/bin/rsync"
else
  RSYNC="/usr/bin/rsync"
fi

# --- Parse Arguments ---
YEAR=""
DRY_RUN_FLAG=""
SKIP_CATALOG=false
while [[ $# -gt 0 ]]; do
  case $1 in
    -y|--year) YEAR="$2"; shift 2 ;;
    -d|--dry-run) DRY_RUN_FLAG="--dry-run"; shift ;;
    --no-catalog) SKIP_CATALOG=true; shift ;;
    -h|--help)
      echo "Usage: $0 [-y|--year YEAR] [-d|--dry-run] [--no-catalog]"
      echo ""
      echo "Options:"
      echo "  -y, --year YEAR    Sync specific year only"
      echo "  -d, --dry-run      Preview changes without syncing"
      echo "  --no-catalog       Skip catalog synchronization"
      echo "  -h, --help         Show this help message"
      exit 0
      ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# --- Sync Function ---
sync_folder() {
    local src="${1%/}/" # Ensure trailing slash
    local dst="${2%/}/" # Ensure trailing slash
    local label="$3"
    
    echo "\n[SYNCING] $label"
    if [[ ! -d "$src" ]]; then
        echo "  [SKIP] Source directory does not exist: $src"
        return
    fi
    
    "$RSYNC" -avh $DRY_RUN_FLAG \
        --size-only \
        --delete \
		--inplace \
        --info=progress2 \
        --stats \
        --exclude='.DS_Store' \
        --exclude='._*' \
        --exclude='.Spotlight-V100' \
        --exclude='.Trashes' \
        --exclude='.fseventsd' \
        --exclude='.TemporaryItems' \
        --exclude='.DocumentRevisions-V100' \
        --exclude='.VolumeIcon.icns' \
        --exclude='Thumbs.db' \
        "$src" "$dst"
}

# --- Setup Logging ---
LOG_DIR=${LOG_DIR/#\~/$HOME}
mkdir -p "$LOG_DIR"
find "$LOG_DIR" -name "sync_log_*.log" -mtime +30 -delete 2>/dev/null

LOG_NAME=${YEAR:-all}
LOG_FILE="${LOG_DIR}/sync_log_${LOG_NAME}_$(date +%Y%m%d_%H%M%S).log"

# --- Execution ---
{
    echo "--- Photo Sync Tool ---"
    echo "[RSYNC]  Using: $RSYNC"
    echo "[DEST]   NAS: $BASE_DESTINATION"
    echo "[DELETE] Enabled - files deleted from source will be removed from NAS"
    [[ "$SKIP_CATALOG" == true ]] && echo "[CATALOG] Skipped (--no-catalog flag set)"
    [[ -n "$DRY_RUN_FLAG" ]] && echo "[MODE]   DRY RUN" || echo "[MODE]   LIVE SYNC"
    echo "=== Sync started at $(date) ==="
    
    # --- 1. Sync Photos ---
    if [[ -n "$YEAR" ]]; then
        sync_folder "${BASE_SOURCE}/photos/${YEAR}" "${BASE_DESTINATION}/photos/${YEAR}" "Photos - Year $YEAR"
    else
        sync_folder "${BASE_SOURCE}/photos" "${BASE_DESTINATION}/photos" "Photos - ALL Years"
    fi
    
    # --- 2. Sync Catalogs ---
    if [[ "$SKIP_CATALOG" == false && -n "$CATALOG" ]]; then
        local -a catalog_pairs
        catalog_pairs=("${(@s:,:)CATALOG}")
        for pair in "${catalog_pairs[@]}"; do
            pair="${pair## }"
            pair="${pair%% }"
            local cat_src="${pair%%:*}"
            local cat_dst="${pair#*:}"
            
            if [[ -n "$cat_src" && -n "$cat_dst" ]]; then
                sync_folder "$cat_src" "$cat_dst" "Catalog: $(basename ${cat_src%/})"
            fi
        done
    elif [[ "$SKIP_CATALOG" == true ]]; then
        echo "\n[CATALOG] Skipping catalog sync (--no-catalog flag set)"
    fi
    
    echo "\n=== Final Summary ==="
    echo "Logs stored at: $LOG_FILE"
    echo "=== Sync completed at $(date) ==="
} | tee "$LOG_FILE"

# Final console-only output
echo "\n--- Process Complete ---"
