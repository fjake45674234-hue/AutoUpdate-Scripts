# AutoUpdate Scripts

Portable, cross-platform monthly system updater.  
Drop these scripts on any machine, run the installer once, and the system will update itself every month — no manual intervention needed.

---

## Files in this folder

| File | Platform | Purpose |
|---|---|---|
| `init.sh` | Linux · macOS · BSD | One-shot installer — run this first |
| `auto_update.sh` | Linux · macOS · BSD | The main updater script |
| `auto_update.ps1` | Windows | Combined installer + updater |

---

## What gets updated

### Operating system packages
| Platform | Tool used |
|---|---|
| Debian · Ubuntu · Kali · Mint | `apt-get` |
| Fedora · RHEL · Rocky · Alma | `dnf` |
| CentOS 7 / RHEL 7 | `yum` |
| Arch · Manjaro · EndeavourOS | `pacman` |
| openSUSE · SLES | `zypper` |
| Void Linux | `xbps-install` |
| Alpine Linux | `apk` |
| Gentoo | `emerge` |
| FreeBSD | `pkg` |
| OpenBSD | `pkg_add` + `syspatch` |
| NetBSD | `pkgin` / `pkg_add` |
| macOS | `softwareupdate` |
| Windows | Windows Update via `PSWindowsUpdate` |

### Drivers & firmware
- **Linux** — `fwupdmgr` (firmware), `ubuntu-drivers`, DKMS module rebuilds
- **macOS** — included in `softwareupdate`
- **Windows** — Windows Update (signed drivers) + NVIDIA / AMD / Intel GPU drivers via `winget`

### Application stores & package managers
`Homebrew` · `Snap` · `Flatpak` · `winget` · `Chocolatey` · `Scoop` · Microsoft Store

### Language & dev toolchains
`pip` / `pipx` · `npm` (global) · `gem` · `rustup` · `cargo` · `conda` / `mamba` · `Go tools` · `Julia` · `poetry` · `nvm` · `asdf` · `volta` · `CPAN`

### Containers
Running Docker and Podman images are pulled to their latest tags; unused images are pruned.

### Editor & shell plugins
Oh My Zsh · Oh My Bash · tmux (tpm) · vim-plug · Neovim lazy.nvim / Packer · VS Code / VSCodium extensions

### Security tools *(Kali / pentesting distros)*
Metasploit (`msfupdate`) · sqlmap · Nuclei templates · searchsploit / exploit-db

---

## Installation & usage

### Linux · macOS · FreeBSD · OpenBSD · NetBSD

**1. Copy both `.sh` files to the target machine.**

**2. Run the installer (once per machine):**

```bash
# Install schedule + run first update immediately
sudo bash init.sh

# Install schedule only (skip first update)
sudo bash init.sh --no-update

# Remove everything
sudo bash init.sh --uninstall
```

The installer will:
- Install `cron` / `cronie` if it isn't already present
- Copy `auto_update.sh` to `/usr/local/sbin/auto-update`
- Register a monthly cron job at `/etc/cron.monthly/auto-update` (Linux/BSD)
- Register a monthly LaunchDaemon on macOS (runs 1st of month at 03:00)
- Create the log file at `/var/log/auto-update.log`

**3. Run manually at any time:**

```bash
sudo /usr/local/sbin/auto-update

# Preview what would run without making changes
sudo /usr/local/sbin/auto-update --dry-run

# With a desktop notification on completion
sudo /usr/local/sbin/auto-update --notify
```

---

### Windows

**1. Copy `auto_update.ps1` to the target machine.**

**2. Open PowerShell as Administrator, then run:**

```powershell
# Install monthly Task Scheduler job (runs 1st of month at 03:00)
powershell -ExecutionPolicy Bypass -File auto_update.ps1 -Install

# Run an update immediately
powershell -ExecutionPolicy Bypass -File auto_update.ps1

# Preview without making changes
powershell -ExecutionPolicy Bypass -File auto_update.ps1 -DryRun
```

The installer will:
- Register a Task Scheduler job that runs as SYSTEM on the 1st of each month at 03:00
- Auto-install the `PSWindowsUpdate` PowerShell module if needed
- Log everything to `C:\Windows\Logs\auto-update.log`

**3. To remove the scheduled task:**

```powershell
Unregister-ScheduledTask -TaskName "MonthlySystemUpdate" -Confirm:$false
```

---

## Logs

| Platform | Log location |
|---|---|
| Linux · macOS · BSD | `/var/log/auto-update.log` |
| Windows | `C:\Windows\Logs\auto-update.log` |

```bash
# Live log tail (Linux/macOS)
tail -f /var/log/auto-update.log
```

Logs rotate automatically when they exceed 10 MB.

---

## Reboot handling

The scripts **never reboot automatically**. If a reboot is required after an update:

- **Linux/BSD** — a flag file is created at `/var/run/auto-update-reboot-required` and a message is written to the log
- **Windows** — a message is written to the log and the Windows Application Event Log

Check for a pending reboot:

```bash
# Linux/BSD
ls /var/run/auto-update-reboot-required 2>/dev/null && echo "Reboot needed" || echo "No reboot needed"
```

```powershell
# Windows
Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
```

---

## Safety features

| Feature | Detail |
|---|---|
| Lock file | Prevents two update runs from overlapping |
| Network check | Aborts if there is no internet connectivity |
| Disk space check | Aborts if less than 500 MB free |
| Dry-run mode | `--dry-run` / `-DryRun` shows what would run without changing anything |
| Log rotation | Log files are rotated at 10 MB |
| No forced reboots | Reboot requirement is logged only — never triggered automatically |

---

## Customisation (Linux/macOS)

Create `/etc/auto-update.conf` to enable or disable sections:

```bash
UPDATE_OS_PACKAGES=true
UPDATE_DRIVERS=true
UPDATE_FIRMWARE=true
UPDATE_CONTAINERS=true
UPDATE_APP_MANAGERS=true
UPDATE_DEV_TOOLS=true
UPDATE_PLUGINS=true
UPDATE_SECURITY_TOOLS=true
```

Set any value to `false` to skip that section.
