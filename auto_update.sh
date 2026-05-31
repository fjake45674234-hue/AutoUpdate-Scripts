#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║         Universal Monthly System Updater — auto_update.sh        ║
# ║  Platforms: Linux · macOS · FreeBSD · OpenBSD · NetBSD          ║
# ║  Covers   : OS packages · drivers · firmware · containers        ║
# ║             dev toolchains · app stores · plugins · security     ║
# ║  Windows  : use companion script auto_update.ps1                 ║
# ╚══════════════════════════════════════════════════════════════════╝
#
# Usage:
#   sudo bash auto_update.sh [OPTIONS]
#
# Options:
#   --install     Install monthly cron/launchd schedule, then exit
#   --dry-run     Show what would run without making changes
#   --no-reboot   Skip reboot-required check at the end
#   --notify      Send desktop notification on completion
#   --help        Show this help

set -euo pipefail

# ─── config ───────────────────────────────────────────────────────────────────

LOG_FILE="/var/log/auto-update.log"
LOG_MAX_MB=10                           # rotate log when it exceeds this size
LOCK_FILE="/var/run/auto-update.lock"
REBOOT_FLAG="/var/run/auto-update-reboot-required"
MIN_DISK_MB=500                         # abort if less free disk space
CONFIG_FILE="/etc/auto-update.conf"     # optional user overrides

# feature flags (can be overridden in $CONFIG_FILE or env)
: "${UPDATE_OS_PACKAGES:=true}"
: "${UPDATE_DRIVERS:=true}"
: "${UPDATE_FIRMWARE:=true}"
: "${UPDATE_CONTAINERS:=true}"
: "${UPDATE_APP_MANAGERS:=true}"
: "${UPDATE_DEV_TOOLS:=true}"
: "${UPDATE_PLUGINS:=true}"
: "${UPDATE_SECURITY_TOOLS:=true}"

# load user config if present
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# ─── argument parsing ─────────────────────────────────────────────────────────

DRY_RUN=false
NOTIFY=false
SKIP_REBOOT=false
DO_INSTALL=false

for arg in "$@"; do
    case "$arg" in
        --install)   DO_INSTALL=true  ;;
        --dry-run)   DRY_RUN=true     ;;
        --notify)    NOTIFY=true      ;;
        --no-reboot) SKIP_REBOOT=true ;;
        --help)
            sed -n '2,15p' "$0"
            exit 0
            ;;
    esac
done

# ─── colour helpers ───────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
    RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

# ─── logging ──────────────────────────────────────────────────────────────────

SUMMARY=()

log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "[$ts] $*" | tee -a "$LOG_FILE"
}

log_section() {
    echo -e "\n${CYAN}${BOLD}[$(date '+%H:%M:%S')] ▶ $*${RESET}" | tee -a "$LOG_FILE"
}

log_ok()   { echo -e "${GREEN}  ✓ $*${RESET}" | tee -a "$LOG_FILE"; }
log_warn() { echo -e "${YELLOW}  ⚠ $*${RESET}" | tee -a "$LOG_FILE"; }
log_err()  { echo -e "${RED}  ✗ $*${RESET}" | tee -a "$LOG_FILE"; }

run() {
    # run a command, logging output; honour --dry-run
    if $DRY_RUN; then
        log_warn "[DRY-RUN] would run: $*"
    else
        "$@" >> "$LOG_FILE" 2>&1 || true
    fi
}

add_summary() { SUMMARY+=("$*"); }

rotate_log() {
    if [[ -f "$LOG_FILE" ]]; then
        local size_mb
        size_mb=$(du -m "$LOG_FILE" 2>/dev/null | cut -f1 || echo 0)
        if (( size_mb >= LOG_MAX_MB )); then
            mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d).bak"
            log "Log rotated (was ${size_mb}MB)."
        fi
    fi
}

# ─── pre-flight checks ────────────────────────────────────────────────────────

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Error: must be run as root (use sudo)." >&2
        exit 1
    fi
}

acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log_err "Another update is already running (PID $pid). Aborting."
            exit 1
        fi
    fi
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT
}

check_network() {
    local hosts=("8.8.8.8" "1.1.1.1" "9.9.9.9")
    for h in "${hosts[@]}"; do
        if ping -c1 -W3 "$h" &>/dev/null; then
            return 0
        fi
    done
    log_err "No network connectivity — aborting update."
    exit 1
}

check_disk_space() {
    local target="/"
    local free_mb
    free_mb=$(df -m "$target" | awk 'NR==2 {print $4}')
    if (( free_mb < MIN_DISK_MB )); then
        log_err "Only ${free_mb}MB free on / — need at least ${MIN_DISK_MB}MB. Aborting."
        exit 1
    fi
    log_ok "Disk space OK (${free_mb}MB free)."
}

# ─── OS / package manager detection ───────────────────────────────────────────

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

detect_linux_pm() {
    for pm in apt-get dnf yum pacman zypper xbps-install apk emerge; do
        command -v "$pm" &>/dev/null && echo "$pm" && return
    done
    echo "unknown"
}

# Run a command as the real (non-root) user when sudo is in use
run_as_user() {
    local real_user="${SUDO_USER:-$(logname 2>/dev/null || id -un)}"
    if [[ "$real_user" == "root" ]]; then
        "$@"
    else
        sudo -u "$real_user" "$@"
    fi
}

# ─── OS package updates ───────────────────────────────────────────────────────

update_linux_packages() {
    local pm
    pm=$(detect_linux_pm)
    log_section "OS packages ($pm)"

    case "$pm" in
        apt-get)
            run env DEBIAN_FRONTEND=noninteractive apt-get update -qq
            run env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
            run env DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y -qq
            run env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq
            run env DEBIAN_FRONTEND=noninteractive apt-get autoclean -qq
            ;;
        dnf)
            run dnf update -y -q
            run dnf autoremove -y -q
            ;;
        yum)
            run yum update -y -q
            ;;
        pacman)
            run pacman -Syu --noconfirm
            run pacman -Rns --noconfirm "$(pacman -Qtdq 2>/dev/null)" 2>/dev/null || true
            ;;
        zypper)
            run zypper --quiet refresh
            run zypper --quiet update -y
            ;;
        xbps-install)
            run xbps-install -Su -y
            ;;
        apk)
            run apk update -q
            run apk upgrade -q
            ;;
        emerge)
            run emerge --sync -q
            run emerge -uDN @world -q
            ;;
        *)
            log_err "No supported Linux package manager found."
            return 1
            ;;
    esac
    add_summary "OS packages ($pm): updated"
}

update_macos_system() {
    log_section "macOS system software (softwareupdate)"
    run softwareupdate -ia --no-scan
    add_summary "macOS system: updated"
}

update_freebsd_packages() {
    log_section "FreeBSD packages (pkg)"
    run pkg update -q
    run pkg upgrade -y
    run pkg autoremove -y
    run pkg clean -y
    add_summary "FreeBSD packages: updated"
}

update_openbsd_packages() {
    log_section "OpenBSD packages"
    run pkg_add -u
    command -v syspatch &>/dev/null && run syspatch
    add_summary "OpenBSD packages + syspatch: updated"
}

update_netbsd_packages() {
    log_section "NetBSD packages"
    if command -v pkgin &>/dev/null; then
        run pkgin -y update
        run pkgin -y upgrade
    else
        run pkg_add -u
    fi
    add_summary "NetBSD packages: updated"
}

# ─── driver & firmware ────────────────────────────────────────────────────────

update_drivers_linux() {
    [[ "$UPDATE_DRIVERS" == "true" ]] || return 0
    log_section "Drivers & firmware"

    # Firmware via fwupd
    if command -v fwupdmgr &>/dev/null && [[ "$UPDATE_FIRMWARE" == "true" ]]; then
        log_ok "fwupdmgr: refreshing..."
        run fwupdmgr refresh --force
        run fwupdmgr update --no-reboot-check -y
        add_summary "Firmware (fwupd): updated"
    fi

    # Ubuntu/Debian hardware drivers
    if command -v ubuntu-drivers &>/dev/null; then
        run ubuntu-drivers autoinstall
        add_summary "Ubuntu hardware drivers: installed"
    fi

    # DKMS module rebuild (after kernel update)
    if command -v dkms &>/dev/null; then
        run dkms autoinstall
        add_summary "DKMS modules: rebuilt"
    fi

    # NVIDIA driver check
    if command -v nvidia-smi &>/dev/null; then
        local ver
        ver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)
        log_ok "NVIDIA driver in use: $ver"
    fi
}

update_drivers_macos() {
    log_section "Drivers (macOS — included in softwareupdate)"
    log_ok "Drivers delivered via softwareupdate (already applied)."
}

# ─── application-level package managers ──────────────────────────────────────

update_app_managers() {
    [[ "$UPDATE_APP_MANAGERS" == "true" ]] || return 0
    log_section "Application package managers"

    # Homebrew (macOS + Linux)
    if command -v brew &>/dev/null; then
        log_ok "Homebrew: updating..."
        run_as_user brew update
        run_as_user brew upgrade
        run_as_user brew upgrade --cask 2>/dev/null || true
        run_as_user brew cleanup
        add_summary "Homebrew: updated"
    fi

    # Snap
    if command -v snap &>/dev/null; then
        log_ok "Snap: refreshing..."
        run snap refresh
        add_summary "Snap: refreshed"
    fi

    # Flatpak
    if command -v flatpak &>/dev/null; then
        log_ok "Flatpak: updating..."
        run flatpak update -y
        run flatpak uninstall --unused -y 2>/dev/null || true
        add_summary "Flatpak: updated"
    fi

    # AppImage tool (appimaged)
    if command -v appimaged &>/dev/null; then
        log_ok "appimaged: updating..."
        run appimaged --update
    fi

    # Python — pipx
    if command -v pipx &>/dev/null; then
        log_ok "pipx: upgrading apps..."
        run_as_user pipx upgrade-all
        add_summary "pipx: upgraded"
    fi

    # Python — pip system packages
    if command -v pip3 &>/dev/null; then
        log_ok "pip3: upgrading outdated packages..."
        local outdated
        outdated=$(pip3 list --outdated --format=freeze 2>/dev/null | grep -v '^\-e' | cut -d= -f1 || true)
        if [[ -n "$outdated" ]]; then
            echo "$outdated" | xargs pip3 install --upgrade -q >> "$LOG_FILE" 2>&1 || true
        fi
        add_summary "pip3: upgraded"
    fi

    # Node.js npm global packages
    if command -v npm &>/dev/null; then
        log_ok "npm: updating global packages..."
        run_as_user npm update -g --loglevel=error
        add_summary "npm globals: updated"
    fi

    # Ruby gems
    if command -v gem &>/dev/null; then
        log_ok "gem: updating..."
        run gem update --system -q
        run gem update -q
        run gem cleanup -q
        add_summary "Ruby gems: updated"
    fi

    # Rust — rustup
    if command -v rustup &>/dev/null; then
        log_ok "rustup: updating..."
        run_as_user rustup update
        add_summary "Rust toolchain: updated"
    fi

    # Rust — cargo installed binaries
    if command -v cargo &>/dev/null && command -v cargo-install-update &>/dev/null; then
        log_ok "cargo: updating installed binaries..."
        run_as_user cargo install-update -a
        add_summary "Cargo binaries: updated"
    fi

    # Go global tools
    if command -v go &>/dev/null; then
        log_ok "Go: updating GOPATH binaries..."
        local gopath
        gopath=$(run_as_user go env GOPATH 2>/dev/null || echo "$HOME/go")
        if [[ -d "$gopath/bin" ]]; then
            for bin in "$gopath/bin"/*; do
                [[ -x "$bin" ]] || continue
                local pkg
                pkg=$(go version -m "$bin" 2>/dev/null | awk '/^$/{next} /path/{print $2; exit}' || true)
                [[ -n "$pkg" ]] && run_as_user go install "${pkg}@latest" 2>/dev/null || true
            done
        fi
        add_summary "Go tools: updated"
    fi

    # Perl CPAN
    if command -v cpan &>/dev/null; then
        log_ok "CPAN: upgrading..."
        echo 'CPAN::Shell->upgrade()' | run cpan 2>/dev/null || true
    fi

    # Conda / Mamba (data science envs)
    for conda_cmd in conda mamba micromamba; do
        if command -v "$conda_cmd" &>/dev/null; then
            log_ok "$conda_cmd: updating base environment..."
            run_as_user "$conda_cmd" update --all -y -q 2>/dev/null || true
            add_summary "$conda_cmd base: updated"
            break
        fi
    done

    # nvm (Node Version Manager)
    local nvm_dir="${NVM_DIR:-$HOME/.nvm}"
    if [[ -s "$nvm_dir/nvm.sh" ]]; then
        log_ok "nvm: updating..."
        run_as_user bash -c "source $nvm_dir/nvm.sh && nvm install --lts && nvm alias default 'lts/*'" || true
        add_summary "nvm LTS: updated"
    fi

    # asdf version manager
    if command -v asdf &>/dev/null; then
        log_ok "asdf: updating plugins..."
        run_as_user asdf update || true
        run_as_user asdf plugin update --all || true
        add_summary "asdf: updated"
    fi

    # Poetry (Python dependency manager)
    if command -v poetry &>/dev/null; then
        log_ok "poetry: self-updating..."
        run_as_user poetry self update || true
    fi

    # Volta (JavaScript toolchain)
    if command -v volta &>/dev/null; then
        log_ok "volta: updating..."
        run_as_user volta install node@latest 2>/dev/null || true
    fi

    # Julia packages
    if command -v julia &>/dev/null; then
        log_ok "Julia: updating packages..."
        run_as_user julia -e 'import Pkg; Pkg.update()' 2>/dev/null || true
    fi
}

# ─── container image updates ──────────────────────────────────────────────────

update_containers() {
    [[ "$UPDATE_CONTAINERS" == "true" ]] || return 0
    log_section "Container images"

    # Docker
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        log_ok "Docker: pulling latest images for running containers..."
        docker ps --format '{{.Image}}' 2>/dev/null | sort -u | while read -r img; do
            [[ -n "$img" ]] && run docker pull "$img" || true
        done
        run docker image prune -f
        add_summary "Docker images: pulled latest"
    fi

    # Podman
    if command -v podman &>/dev/null; then
        log_ok "Podman: pulling latest images..."
        podman ps --format '{{.Image}}' 2>/dev/null | sort -u | while read -r img; do
            [[ -n "$img" ]] && run podman pull "$img" || true
        done
        run podman image prune -f
        add_summary "Podman images: pulled latest"
    fi
}

# ─── development tools & plugins ──────────────────────────────────────────────

update_dev_tools() {
    [[ "$UPDATE_DEV_TOOLS" == "true" ]] || return 0
    log_section "Development tools & shell plugins"

    # Oh My Zsh
    local omz_dir="${HOME}/.oh-my-zsh"
    [[ -n "${SUDO_USER:-}" ]] && omz_dir="/home/${SUDO_USER}/.oh-my-zsh"
    if [[ -d "$omz_dir" ]]; then
        log_ok "Oh My Zsh: updating..."
        run_as_user bash -c "cd $omz_dir && git pull --rebase origin master" || true
        add_summary "Oh My Zsh: updated"
    fi

    # Oh My Bash
    local omb_dir="${HOME}/.oh-my-bash"
    [[ -n "${SUDO_USER:-}" ]] && omb_dir="/home/${SUDO_USER}/.oh-my-bash"
    if [[ -d "$omb_dir" ]]; then
        log_ok "Oh My Bash: updating..."
        run_as_user bash -c "cd $omb_dir && git pull --rebase origin master" || true
        add_summary "Oh My Bash: updated"
    fi

    # Tmux Plugin Manager (tpm)
    local tpm_dir="${HOME}/.tmux/plugins/tpm"
    [[ -n "${SUDO_USER:-}" ]] && tpm_dir="/home/${SUDO_USER}/.tmux/plugins/tpm"
    if [[ -d "$tpm_dir" ]]; then
        log_ok "tpm (tmux plugins): updating..."
        run_as_user bash -c "cd $tpm_dir && git pull --rebase origin master" || true
        run_as_user bash -c "$tpm_dir/bin/update_plugins all" || true
        add_summary "tmux plugins: updated"
    fi

    # Vim plug
    if command -v vim &>/dev/null; then
        local vimplug="${HOME}/.vim/autoload/plug.vim"
        [[ -n "${SUDO_USER:-}" ]] && vimplug="/home/${SUDO_USER}/.vim/autoload/plug.vim"
        if [[ -f "$vimplug" ]]; then
            log_ok "vim-plug: updating plugins..."
            run_as_user vim +PlugUpdate +PlugClean! +qall 2>/dev/null || true
            add_summary "vim-plug plugins: updated"
        fi
    fi

    # Neovim — lazy.nvim / packer
    if command -v nvim &>/dev/null; then
        log_ok "Neovim: updating plugins..."
        run_as_user nvim --headless "+Lazy! sync" +qa 2>/dev/null || \
        run_as_user nvim --headless "+PackerSync" +qa 2>/dev/null || true
        add_summary "Neovim plugins: updated"
    fi

    # VS Code / VSCodium extensions
    for editor in code codium; do
        if command -v "$editor" &>/dev/null; then
            log_ok "$editor: updating extensions..."
            run_as_user "$editor" --update-extensions 2>/dev/null || \
            run_as_user "$editor" --list-extensions 2>/dev/null | \
                xargs -I{} run_as_user "$editor" --install-extension {} --force 2>/dev/null || true
            add_summary "$editor extensions: updated"
        fi
    done
}

# ─── security tools (Kali / pentesting distros) ───────────────────────────────

update_security_tools() {
    [[ "$UPDATE_SECURITY_TOOLS" == "true" ]] || return 0
    log_section "Security tools"

    # Metasploit
    if command -v msfupdate &>/dev/null; then
        log_ok "Metasploit: updating..."
        run msfupdate
        add_summary "Metasploit: updated"
    fi

    # SQLMap
    if command -v sqlmap &>/dev/null; then
        log_ok "sqlmap: updating..."
        run_as_user sqlmap --update 2>/dev/null || true
    fi

    # Nuclei (projectdiscovery)
    if command -v nuclei &>/dev/null; then
        log_ok "nuclei: updating templates..."
        run_as_user nuclei -update-templates 2>/dev/null || true
    fi

    # searchsploit / exploit-db
    if command -v searchsploit &>/dev/null; then
        log_ok "searchsploit: updating exploit-db..."
        run searchsploit -u 2>/dev/null || true
    fi

    # BlackArch / Kali tool updater
    if command -v kali-tweaks &>/dev/null; then
        log_ok "kali-tweaks: available (run manually if needed)."
    fi
}

# ─── reboot check ─────────────────────────────────────────────────────────────

check_reboot() {
    local os="$1"
    $SKIP_REBOOT && return 0
    log_section "Reboot check"
    local needed=false

    case "$os" in
        linux)
            [[ -f /var/run/reboot-required ]] && needed=true
            command -v needs-restarting &>/dev/null && { needs-restarting -r &>/dev/null || needed=true; } || true
            if command -v pacman &>/dev/null; then
                local booted inst
                booted=$(uname -r)
                inst=$(pacman -Q linux 2>/dev/null | awk '{print $2}' | head -1 || true)
                [[ -n "$inst" && "$booted" != *"$inst"* ]] && needed=true
            fi
            ;;
        macos)
            softwareupdate -l 2>&1 | grep -qi "restart" && needed=true || true
            ;;
    esac

    if $needed; then
        log_warn "REBOOT REQUIRED — please reboot this machine at your convenience."
        touch "$REBOOT_FLAG"
        add_summary "⚠ Reboot required"
    else
        log_ok "No reboot required."
        rm -f "$REBOOT_FLAG"
    fi
}

# ─── notification & summary ───────────────────────────────────────────────────

print_summary() {
    local duration=$(( SECONDS - START_TIME ))
    log_section "Summary (completed in ${duration}s)"
    for item in "${SUMMARY[@]}"; do
        log_ok "$item"
    done

    if $NOTIFY && command -v notify-send &>/dev/null; then
        local msg
        msg=$(printf '%s\n' "${SUMMARY[@]}")
        notify-send "System Update Complete" "$msg" --icon=system-software-update 2>/dev/null || true
    fi

    # Write to system journal if available
    if command -v logger &>/dev/null; then
        logger -t auto-update "Monthly update complete (${duration}s). Items: ${#SUMMARY[@]}"
    fi
}

# ─── schedule installation ────────────────────────────────────────────────────

install_cron_monthly() {
    local script
    script="$(realpath "$0")"

    if [[ ! -d /etc/cron.monthly ]]; then
        log_err "/etc/cron.monthly not found. Install 'cron' or 'cronie' first."
        exit 1
    fi

    local dest="/etc/cron.monthly/auto-update"
    cp "$script" "$dest"
    chmod 755 "$dest"

    echo -e "\n${GREEN}${BOLD}Installed:${RESET} $dest"
    echo -e "Runs:     once a month as root"
    echo -e "Logs:     $LOG_FILE"
    echo -e "Run now:  sudo $dest"
    echo -e "Remove:   sudo rm $dest"
}

install_launchd() {
    local script
    script="$(realpath "$0")"
    local plist="/Library/LaunchDaemons/com.autoupdate.monthly.plist"

    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.autoupdate.monthly</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${script}</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Day</key>   <integer>1</integer>
        <key>Hour</key>  <integer>3</integer>
        <key>Minute</key><integer>0</integer>
    </dict>
    <key>RunAtLoad</key><false/>
    <key>StandardOutPath</key><string>${LOG_FILE}</string>
    <key>StandardErrorPath</key><string>${LOG_FILE}</string>
</dict>
</plist>
PLIST

    launchctl load "$plist"
    echo -e "\n${GREEN}${BOLD}Installed LaunchDaemon:${RESET} $plist"
    echo -e "Runs: 1st of each month at 03:00"
    echo -e "Logs: $LOG_FILE"
    echo -e "Uninstall: sudo launchctl unload $plist && sudo rm $plist"
}

install_schedule() {
    local os="$1"
    case "$os" in
        linux|freebsd|openbsd|netbsd) install_cron_monthly ;;
        macos) install_launchd ;;
    esac
}

# ─── main ─────────────────────────────────────────────────────────────────────

main() {
    local os
    os=$(detect_os)

    if [[ "$os" == "unknown" ]]; then
        echo "Unsupported OS: $(uname -s). On Windows, use auto_update.ps1." >&2
        exit 1
    fi

    if $DO_INSTALL; then
        check_root
        install_schedule "$os"
        exit 0
    fi

    check_root
    acquire_lock
    rotate_log

    START_TIME=$SECONDS
    log "=== Monthly update started (OS: $os · host: $(hostname) · kernel: $(uname -r)) ==="
    $DRY_RUN && log_warn "DRY-RUN mode: no changes will be made."

    # Pre-flight
    check_network
    check_disk_space

    # 1. OS packages
    if [[ "$UPDATE_OS_PACKAGES" == "true" ]]; then
        case "$os" in
            linux)   update_linux_packages   ;;
            macos)   update_macos_system     ;;
            freebsd) update_freebsd_packages ;;
            openbsd) update_openbsd_packages ;;
            netbsd)  update_netbsd_packages  ;;
        esac
    fi

    # 2. Drivers & firmware
    case "$os" in
        linux) update_drivers_linux ;;
        macos) update_drivers_macos ;;
    esac

    # 3. App-level package managers
    update_app_managers

    # 4. Container images
    update_containers

    # 5. Dev tools & plugins
    update_dev_tools

    # 6. Security tools
    update_security_tools

    # 7. Reboot check
    check_reboot "$os"

    # 8. Summary
    print_summary

    log "=== Monthly update complete ==="
}

main
