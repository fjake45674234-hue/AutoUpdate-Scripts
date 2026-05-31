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

## Requirements

### Windows
- **PowerShell 7** (`pwsh`) — required. Install via:
  ```powershell
  winget install Microsoft.PowerShell --accept-package-agreements --accept-source-agreements
  ```
- **Administrator privileges** — the script must be run elevated
- `PSWindowsUpdate` module — installed automatically on first run

### Linux · macOS · BSD
- Bash 4+
- Root / sudo access
- `cron` or `cronie` — installed automatically if missing

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

### Drivers & firmware (Windows)

Full 7-step driver update covering every device in Device Manager:

| Step | What it does |
|---|---|
| Windows Update driver pass | Installs all Microsoft-signed drivers via PSWindowsUpdate |
| `pnputil /scan-devices` | Device Manager-style scan — detects new/changed hardware |
| PnP device loop | Iterates every device and pushes the latest available driver |
| DISM health check | Audits the driver store for corruption |
| Vendor tools (winget) | NVIDIA · AMD · Intel · Realtek · Logitech · Corsair · Razer · Xbox Accessories |
| Device cycling | JBL · Xbox/XINPUT · USB hubs — disable/enable cycle to reload drivers |
| Service restarts | Bluetooth (`bthserv`) · Windows Audio (`Audiosrv`, `AudioEndpointBuilder`) |

Virtual/transient devices (audio endpoints `SWD\MMDEVAPI`, shadow copies `STORAGE\VOLUMESNAPSHOT`) are automatically excluded from the problem report.

### Drivers & firmware (Linux · macOS)
- **Linux** — `fwupdmgr` (firmware), `ubuntu-drivers`, DKMS module rebuilds
- **macOS** — included in `softwareupdate`

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

### Windows

> **Requires PowerShell 7 (`pwsh`) and Administrator privileges.**

**1. Copy `auto_update.ps1` to the target machine.**

**2. Open PowerShell 7 as Administrator, then run:**

```powershell
# Install monthly Task Scheduler job (runs 1st of month at 03:00 as SYSTEM)
pwsh -ExecutionPolicy Bypass -File auto_update.ps1 -Install

# Run an update immediately
pwsh -ExecutionPolicy Bypass -File auto_update.ps1

# Preview without making changes
pwsh -ExecutionPolicy Bypass -File auto_update.ps1 -DryRun

# Run with desktop notification on completion
pwsh -ExecutionPolicy Bypass -File auto_update.ps1 -Notify
```

The installer will:
- Register a Task Scheduler job that runs as SYSTEM on the 1st of each month at 03:00
- Auto-install the `PSWindowsUpdate` module if needed
- Log everything to `C:\Windows\Logs\auto-update.log`

**3. To remove the scheduled task:**

```powershell
Unregister-ScheduledTask -TaskName "MonthlySystemUpdate" -Confirm:$false
```

---

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

## Logs

| Platform | Log location |
|---|---|
| Linux · macOS · BSD | `/var/log/auto-update.log` |
| Windows | `C:\Windows\Logs\auto-update.log` |

```bash
# Live log tail (Linux/macOS)
tail -f /var/log/auto-update.log
```

```powershell
# Live log tail (Windows)
Get-Content "C:\Windows\Logs\auto-update.log" -Wait -Tail 20
```

Logs rotate automatically when they exceed 10 MB. Windows completion is also written to the Application Event Log (Event ID 1001, Source: `auto-update`).

---

## Reboot handling

The scripts **never reboot automatically**. If a reboot is required after an update:

- **Linux/BSD** — a flag file is created at `/var/run/auto-update-reboot-required` and a message is written to the log
- **Windows** — a warning is written to the log and the Application Event Log

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
| Lock file | Prevents two update runs from overlapping (`%TEMP%\auto-update.lock`) |
| Network check | Aborts if there is no internet connectivity |
| Disk space check | Aborts if less than 500 MB free |
| Dry-run mode | `--dry-run` / `-DryRun` — shows what would run without changing anything |
| Log rotation | Log files are rotated at 10 MB |
| No forced reboots | Reboot requirement is logged only — never triggered automatically |
| Event log | Windows: completion written to Application Event Log (Event ID 1001) |

---

## Customisation

### Windows — feature flags (top of `auto_update.ps1`)

```powershell
$UpdateOsPackages  = $true   # Windows Update patches
$UpdateDrivers     = $true   # Full device driver update (all 7 steps)
$UpdateWinget      = $true   # winget app upgrades
$UpdateChocolatey  = $true   # Chocolatey packages
$UpdateScoop       = $true   # Scoop packages
$UpdateStore       = $true   # Microsoft Store apps
$UpdateAppManagers = $true   # pip · npm · gem · rustup · conda · etc.
$UpdateContainers  = $true   # Docker image pulls
$UpdateDevTools    = $true   # VS Code · Neovim · Git for Windows
```

Set any value to `$false` to skip that section.

### Linux/macOS — config file

Create `/etc/auto-update.conf`:

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

---

## Troubleshooting (Windows)

| Error | Fix |
|---|---|
| `#Requires -RunAsAdministrator` | Run PowerShell 7 as Administrator |
| `pwsh: command not found` | Install PS7: `winget install Microsoft.PowerShell` |
| `Another update is running` | Delete `%TEMP%\auto-update.lock` and retry |
| `PSWindowsUpdate` errors | Run `Install-Module PSWindowsUpdate -Force -Scope AllUsers` manually |
| Devices still Unknown after update | Reboot — shadow copies and virtual audio endpoints clear on restart |
| `Write-EventLog not recognized` | Ensure you are using PowerShell 7 (`pwsh`), not PowerShell 5 (`powershell`) |
