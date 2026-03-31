#!/bin/bash
# Install zig-coreutils
# Usage: ./install.sh [OPTIONS]
#
# Options:
#   --dest DIR       Install to DIR (default: /usr/local/bin)
#   --no-z           Strip 'z' prefix (zcat -> cat, zls -> ls)
#   --copy           Copy binaries instead of symlinks
#   --uninstall      Remove installed binaries/symlinks
#   --backup DIR     Backup existing binaries to DIR before replacing
#   --dry-run        Show what would be done without doing it
#
# Examples:
#   ./install.sh                          # Symlink with z prefix to /usr/local/bin
#   ./install.sh --no-z --dest /opt/bin   # Install without z prefix
#   ./install.sh --no-z --backup ~/backup # Replace coreutils, backup originals

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="/usr/local/bin"
STRIP_Z=false
USE_COPY=false
UNINSTALL=false
BACKUP_DIR=""
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dest)
            DEST="$2"
            shift 2
            ;;
        --no-z)
            STRIP_Z=true
            shift
            ;;
        --copy)
            USE_COPY=true
            shift
            ;;
        --uninstall)
            UNINSTALL=true
            shift
            ;;
        --backup)
            BACKUP_DIR="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            head -20 "$0" | tail -18
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Find all built binaries
mapfile -t binaries < <(find "$SCRIPT_DIR" -path "*/zig-out/bin/*" -type f -executable 2>/dev/null | sort)

if [[ ${#binaries[@]} -eq 0 ]]; then
    echo "No binaries found. Run ./build-all.sh first."
    exit 1
fi

echo "Found ${#binaries[@]} binaries"
echo "Destination: $DEST"
echo "Strip 'z' prefix: $STRIP_Z"
echo "Method: $(if $USE_COPY; then echo 'copy'; else echo 'symlink'; fi)"
if [[ -n "$BACKUP_DIR" ]]; then
    echo "Backup dir: $BACKUP_DIR"
fi
if $DRY_RUN; then
    echo "** DRY RUN - no changes will be made **"
fi
echo ""

# Create destination if needed
if ! $DRY_RUN && [[ ! -d "$DEST" ]]; then
    echo "Creating $DEST..."
    sudo mkdir -p "$DEST"
fi

# Create backup dir if specified
if [[ -n "$BACKUP_DIR" ]] && ! $DRY_RUN; then
    mkdir -p "$BACKUP_DIR"
fi

installed=0
skipped=0
backed_up=0

for bin in "${binaries[@]}"; do
    base=$(basename "$bin")

    # Determine target name
    if $STRIP_Z; then
        # Remove leading 'z' if present
        if [[ "$base" == z* ]]; then
            target="${base:1}"
        else
            target="$base"
        fi
    else
        target="$base"
    fi

    dest_path="$DEST/$target"

    if $UNINSTALL; then
        # Uninstall mode
        if [[ -e "$dest_path" || -L "$dest_path" ]]; then
            if $DRY_RUN; then
                echo "Would remove: $dest_path"
            else
                sudo rm -f "$dest_path"
                echo "Removed: $dest_path"
            fi
            ((installed++))
        fi
        continue
    fi

    # Backup existing file if requested
    if [[ -n "$BACKUP_DIR" ]] && [[ -e "$dest_path" ]] && [[ ! -L "$dest_path" ]]; then
        if $DRY_RUN; then
            echo "Would backup: $dest_path -> $BACKUP_DIR/$target"
        else
            cp "$dest_path" "$BACKUP_DIR/$target"
            echo "Backed up: $target"
        fi
        ((backed_up++))
    fi

    # Skip if target exists and is a symlink to this binary
    if [[ -L "$dest_path" ]]; then
        existing=$(readlink -f "$dest_path" 2>/dev/null || true)
        if [[ "$existing" == "$bin" ]]; then
            ((skipped++))
            continue
        fi
    fi

    if $DRY_RUN; then
        if $USE_COPY; then
            echo "Would copy: $bin -> $dest_path"
        else
            echo "Would link: $bin -> $dest_path"
        fi
    else
        # Remove existing
        sudo rm -f "$dest_path"

        if $USE_COPY; then
            sudo cp "$bin" "$dest_path"
            sudo chmod 755 "$dest_path"
        else
            sudo ln -s "$bin" "$dest_path"
        fi
    fi
    ((installed++))
done

echo ""
echo "========================================="
if $UNINSTALL; then
    echo "Removed: $installed"
else
    echo "Installed: $installed"
    echo "Skipped (already installed): $skipped"
    if [[ $backed_up -gt 0 ]]; then
        echo "Backed up: $backed_up (in $BACKUP_DIR)"
    fi
fi
echo "========================================="

if $STRIP_Z && ! $UNINSTALL && ! $DRY_RUN; then
    echo ""
    echo "WARNING: Installed without 'z' prefix."
    echo "These may override system utilities in $DEST"
    echo "To restore, run: ./install.sh --uninstall --no-z --dest $DEST"
fi
