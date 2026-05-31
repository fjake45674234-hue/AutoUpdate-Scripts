#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║              Auto-Update Initializer — init.sh                   ║
# ║  Installs auto_update.sh on any Unix-like system in one step.   ║
# ║  Run this once on each machine; it handles everything else.     ║
# ╚══════════════════════════════════════════════════════════════════╝
#
# Platforms: Linux · macOS · FreeBSD · OpenBSD · NetBSD
# Windows  : use auto_update.ps1 instead (requires PowerShell 7 + admin)
#            pwsh -ExecutionPolicy Bypass -File auto_update.ps1 -Install
#
# Usage:
#   sudo bash init.sh               # install and run first update
#   sudo bash init.sh --no-update   # install schedule only, skip first run
#   sudo bash init.sh --uninstall   # remove everything

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_SCRIPT="$SCRIPT_DIR/auto_update.sh"
INSTALL_DIR="/usr/local/sbin"
INSTALLED="$INSTALL_DIR/auto-update"
LOG_FILE="/var/log/auto-update.log"
CRON_DEST="/etc/cron.monthly/auto-update"
LAUNCHD_PLIST="/Library/LaunchDaemons/com.autoupdate.monthly.plist"

# ─── colour helpers ───────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
    R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
    C='\033[0;36m'; B='\033[1m'; X='\033[0m'
else
    R=''; G=''; Y=''; C=''; B=''; X=''
fi

info()    { echo -e "${C}${B}[init]${X} $*"; }
ok()      { echo -e "${G}  ✓${X} $*"; }
warn()    { echo -e "${Y}  ⚠${X} $*"; }
fail()    { echo -e "${R}  ✗${X} $*" >&2; }
section() { echo -e "\n${B}── $* ──${X}"; }

# ─── checks ───────────────────────────────────────────────────────────────────

check_root() {
    [[ $EUID -eq 0 ]] || { fail "Please run as root: sudo bash init.sh"; exit 1; }
}

detect_os() {
    case "$(uname -s)" in
        Linux)   echo "linux"   ;;
        Darwin)  echo "macos"   ;;
        FreeBSD) echo "freebsd" ;;
        OpenBSD) echo "openbsd" ;;
        NetBSD)  echo "netbsd"  ;;
        *)       echo "unknown" ;;
    esac
}

check_main_script() {
    if [[ ! -f "$MAIN_SCRIPT" ]]; then
        fail "auto_update.sh not found in $SCRIPT_DIR"
        fail "Place init.sh and auto_update.sh in the same directory."
        exit 1
    fi
}

# ─── dependency installation ──────────────────────────────────────────────────

install_cron_if_missing() {
    local os="$1"
    [[ "$os" != "linux" ]] && return 0

    if [[ ! -d /etc/cron.monthly ]]; then
        info "cron not found — installing..."
        if command -v apt-get &>/dev/null; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cron
        elif command -v dnf &>/dev/null; then
            dnf install -y -q cronie
            systemctl enable --now crond
        elif command -v yum &>/dev/null; then
            yum install -y -q cronie
            systemctl enable --now crond
        elif command -v pacman &>/dev/null; then
            pacman -Sy --noconfirm cronie
            systemctl enable --now cronie
        elif command -v zypper &>/dev/null; then
            zypper --quiet install -y cron
            systemctl enable --now cron
        elif command -v apk &>/dev/null; then
            apk add -q dcron
            rc-update add dcron default
            service dcron start
        else
            fail "Cannot install cron — install it manually and re-run."
            exit 1
        fi
        ok "cron installed."
    else
        ok "cron already present."
    fi
}

# ─── install ──────────────────────────────────────────────────────────────────

do_install() {
    local os="$1"
    section "Installing auto-update on $os"

    # 1. Install cron if needed (Linux)
    install_cron_if_missing "$os"

    # 2. Create log file with correct permissions
    touch "$LOG_FILE"
    chmod 640 "$LOG_FILE"
    ok "Log file ready: $LOG_FILE"

    # 3. Copy script to system path
    mkdir -p "$INSTALL_DIR"
    cp "$MAIN_SCRIPT" "$INSTALLED"
    chmod 755 "$INSTALLED"
    ok "Script installed: $INSTALLED"

    # 4. Register the schedule
    case "$os" in
        linux|freebsd|openbsd|netbsd)
            cp "$INSTALLED" "$CRON_DEST"
            chmod 755 "$CRON_DEST"
            ok "Monthly cron job installed: $CRON_DEST"
            ;;
        macos)
            bash "$INSTALLED" --install
            ok "Monthly LaunchDaemon installed."
            ;;
    esac

    echo ""
    echo -e "${G}${B}Installation complete.${X}"
    echo -e "  Script : $INSTALLED"
    echo -e "  Logs   : $LOG_FILE"
    echo -e "  Run now: sudo $INSTALLED"
    echo ""
}

# ─── uninstall ────────────────────────────────────────────────────────────────

do_uninstall() {
    local os="$1"
    section "Removing auto-update"

    [[ -f "$INSTALLED"    ]] && { rm -f "$INSTALLED";    ok "Removed $INSTALLED"; }
    [[ -f "$CRON_DEST"    ]] && { rm -f "$CRON_DEST";    ok "Removed $CRON_DEST"; }

    if [[ "$os" == "macos" && -f "$LAUNCHD_PLIST" ]]; then
        launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
        rm -f "$LAUNCHD_PLIST"
        ok "Removed LaunchDaemon: $LAUNCHD_PLIST"
    fi

    warn "Log file kept at $LOG_FILE — remove manually if desired."
    ok "Uninstall complete."
}

# ─── main ─────────────────────────────────────────────────────────────────────

main() {
    local no_update=false
    local uninstall=false

    for arg in "$@"; do
        case "$arg" in
            --no-update) no_update=true  ;;
            --uninstall) uninstall=true  ;;
        esac
    done

    check_root
    check_main_script

    local os
    os=$(detect_os)

    if [[ "$os" == "unknown" ]]; then
        fail "Unsupported OS: $(uname -s)"
        exit 1
    fi

    if $uninstall; then
        do_uninstall "$os"
        exit 0
    fi

    do_install "$os"

    if ! $no_update; then
        section "Running first update now"
        info "This may take several minutes..."
        bash "$INSTALLED"
    else
        info "Skipping first update (--no-update). Run manually: sudo $INSTALLED"
    fi
}

main "$@"
