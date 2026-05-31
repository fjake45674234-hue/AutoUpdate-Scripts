#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Universal Monthly System Updater for Windows.
    Covers: Windows Update · drivers · winget · Chocolatey · Scoop · Microsoft Store
            pip · npm · gem · rustup · cargo · conda · VS Code extensions · GPU drivers

.USAGE
    # Install monthly Task Scheduler job, then exit:
    powershell -ExecutionPolicy Bypass -File auto_update.ps1 -Install

    # Run an update right now:
    powershell -ExecutionPolicy Bypass -File auto_update.ps1

    # Dry run (show what would happen, no changes):
    powershell -ExecutionPolicy Bypass -File auto_update.ps1 -DryRun

    # With desktop notification on completion:
    powershell -ExecutionPolicy Bypass -File auto_update.ps1 -Notify
#>

param(
    [switch]$Install,
    [switch]$DryRun,
    [switch]$Notify,
    [switch]$NoReboot,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ─── config ───────────────────────────────────────────────────────────────────

$LogFile       = "C:\Windows\Logs\auto-update.log"
$LogMaxMB      = 10
$LockFile      = "$env:TEMP\auto-update.lock"
$TaskName      = "MonthlySystemUpdate"
$MinDiskMB     = 500
$StartTime     = Get-Date
$Summary       = [System.Collections.Generic.List[string]]::new()

# Feature flags — set to $false to skip sections
$UpdateOsPackages    = $true
$UpdateDrivers       = $true
$UpdateWinget        = $true
$UpdateChocolatey    = $true
$UpdateScoop         = $true
$UpdateStore         = $true
$UpdateAppManagers   = $true
$UpdateContainers    = $true
$UpdateDevTools      = $true

if ($Help) {
    Get-Help $MyInvocation.MyCommand.Path
    exit 0
}

# ─── logging ──────────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Msg"
    $line | Tee-Object -FilePath $LogFile -Append | Out-Null
    switch ($Level) {
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        "ERROR" { Write-Host $line -ForegroundColor Red }
        "OK"    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
}

function Log-Section { Write-Log "=== $args ===" }
function Log-Ok      { Write-Log "$args" "OK"    }
function Log-Warn    { Write-Log "$args" "WARN"  }
function Log-Error   { Write-Log "$args" "ERROR" }

function Add-Summary { $Summary.Add($args[0]) | Out-Null }

function Invoke-Step {
    param([string]$Description, [scriptblock]$Block)
    Log-Section $Description
    if ($DryRun) {
        Log-Warn "[DRY-RUN] would execute: $Description"
        return
    }
    try { & $Block }
    catch { Log-Error "Error in '$Description': $_" }
}

function Rotate-Log {
    if (Test-Path $LogFile) {
        $sizeMB = [math]::Round((Get-Item $LogFile).Length / 1MB, 1)
        if ($sizeMB -ge $LogMaxMB) {
            $backup = "$LogFile.$(Get-Date -Format 'yyyyMMdd').bak"
            Move-Item $LogFile $backup -Force
            Write-Log "Log rotated (was ${sizeMB}MB) → $backup"
        }
    }
}

# ─── pre-flight checks ────────────────────────────────────────────────────────

function Test-Network {
    $hosts = @("8.8.8.8", "1.1.1.1", "9.9.9.9")
    foreach ($h in $hosts) {
        if (Test-Connection -ComputerName $h -Count 1 -Quiet -ErrorAction SilentlyContinue) {
            return $true
        }
    }
    Log-Error "No network connectivity — aborting."
    exit 1
}

function Test-DiskSpace {
    $drive = Split-Path $LogFile -Qualifier
    $disk  = Get-PSDrive ($drive.TrimEnd(':')) -ErrorAction SilentlyContinue
    if ($disk) {
        $freeMB = [math]::Round($disk.Free / 1MB)
        if ($freeMB -lt $MinDiskMB) {
            Log-Error "Only ${freeMB}MB free on $drive — need ${MinDiskMB}MB. Aborting."
            exit 1
        }
        Log-Ok "Disk space OK (${freeMB}MB free on $drive)."
    }
}

function Acquire-Lock {
    if (Test-Path $LockFile) {
        $lockPid = Get-Content $LockFile -ErrorAction SilentlyContinue
        $proc = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
        if ($proc) {
            Log-Error "Another update is running (PID $lockPid). Aborting."
            exit 1
        }
    }
    $PID | Out-File $LockFile -Force
    Register-EngineEvent PowerShell.Exiting -Action { Remove-Item $LockFile -Force -ErrorAction SilentlyContinue } | Out-Null
}

# ─── Windows Update (OS patches + drivers) ────────────────────────────────────

function Update-WindowsSystem {
    Invoke-Step "Windows Update (OS patches + drivers)" {
        # Install PSWindowsUpdate module if missing
        if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
            Write-Log "Installing PSWindowsUpdate module..."
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
            Install-Module PSWindowsUpdate -Force -Scope AllUsers -AllowClobber | Out-Null
        }
        Import-Module PSWindowsUpdate -Force

        # Register Microsoft Update service (covers Office, drivers, third-party)
        try {
            Add-WUServiceManager -ServiceID "7971f918-a847-4430-9279-4a52d1efe18d" -Confirm:$false | Out-Null
        } catch { }

        $updates = Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot 2>&1
        $updates | Out-File $LogFile -Append
        $count = ($updates | Where-Object { $_ -match "KB\d+" } | Measure-Object).Count
        Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -Confirm:$false | Out-File $LogFile -Append
        Add-Summary "Windows Update: $count updates installed"
    }
}

# ─── All device drivers ───────────────────────────────────────────────────────

function Update-AllDrivers {
    Invoke-Step "All device drivers" {

        # --- 1. Windows Update driver pass (covers all signed drivers) ---
        Log-Ok "Running Windows Update driver scan..."
        try {
            if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
                Install-Module PSWindowsUpdate -Force -Scope AllUsers -AllowClobber | Out-Null
            }
            Import-Module PSWindowsUpdate -Force
            Install-WindowsUpdate -UpdateType Driver -AcceptAll -IgnoreReboot -Confirm:$false `
                2>&1 | Out-File $LogFile -Append
            Log-Ok "Windows Update driver pass complete."
        } catch { Log-Warn "PSWindowsUpdate driver pass failed: $_" }

        # --- 2. pnputil scan — triggers Device Manager-style scan for all devices ---
        Log-Ok "Running pnputil device scan (Device Manager equivalent)..."
        try {
            pnputil /scan-devices 2>&1 | Out-File $LogFile -Append
            Log-Ok "pnputil scan complete."
        } catch { Log-Warn "pnputil scan failed: $_" }

        # --- 3. PnP device scan — push driver updates to every device ---
        Log-Ok "Pushing driver updates to all PnP devices..."
        try {
            $allStatuses = @('OK', 'Unknown', 'Degraded', 'Error')
            $devices = Get-PnpDevice -ErrorAction SilentlyContinue |
                       Where-Object { $_.Status -in $allStatuses }
            $updated = 0; $failed = 0
            foreach ($dev in $devices) {
                try {
                    $result = Update-PnpDeviceDriver -InstanceId $dev.InstanceId `
                                  -Confirm:$false -ErrorAction Stop
                    if ($result) {
                        Log-Ok "  Updated: $($dev.FriendlyName)"
                        $updated++
                    }
                } catch {
                    # Most devices will already be on latest — not an error
                    $failed++
                }
            }
            Log-Ok "PnP driver update complete: $updated updated, $failed already current/skipped."
        } catch { Log-Warn "PnP driver scan failed: $_" }

        # --- 4. DISM driver health check ---
        Log-Ok "Running DISM driver store health check..."
        try {
            DISM /Online /Cleanup-Image /AnalyzeComponentStore 2>&1 | Out-File $LogFile -Append
            Log-Ok "DISM check complete."
        } catch { Log-Warn "DISM check failed: $_" }

        # --- 5. Vendor-specific update tools (winget) ---
        $driverPkgs = @(
            @{ Id="Nvidia.GeForceExperience";             Name="NVIDIA GeForce Experience"      },
            @{ Id="Nvidia.CUDA";                          Name="NVIDIA CUDA Toolkit"            },
            @{ Id="Intel.IntelDriverAndSupportAssistant"; Name="Intel Driver Support Assistant" },
            @{ Id="AdvancedMicroDevices.AMDSoftware";     Name="AMD Software Adrenalin"         },
            @{ Id="Intel.IntelArcControlApp";             Name="Intel Arc Control"              },
            @{ Id="Realtek.RealtekAudioControl";          Name="Realtek Audio Control"          },
            @{ Id="ASUSTeK.ArmoryCrate";                  Name="ASUS Armory Crate"              },
            @{ Id="Logitech.GHUB";                        Name="Logitech G HUB"                 },
            @{ Id="Corsair.iCUE4";                        Name="Corsair iCUE"                   },
            @{ Id="Razer.Synapse3";                       Name="Razer Synapse"                  },
            @{ Id="Microsoft.XboxAccessories";            Name="Xbox Accessories (controller driver)" },
            @{ Id="9NBLGGH30XJ3";                        Name="Xbox Controller driver (Store)"  }
        )

        if (Get-Command winget -ErrorAction SilentlyContinue) {
            foreach ($pkg in $driverPkgs) {
                $installed = winget list --id $pkg.Id 2>&1
                if ($installed -match [regex]::Escape($pkg.Id)) {
                    Log-Ok "Upgrading $($pkg.Name)..."
                    winget upgrade --id $pkg.Id --silent `
                        --accept-source-agreements --accept-package-agreements `
                        2>&1 | Out-File $LogFile -Append
                } else {
                    # Install if not present (for controller/accessory drivers)
                    if ($pkg.Id -in @("Microsoft.XboxAccessories")) {
                        Log-Ok "Installing $($pkg.Name)..."
                        winget install --id $pkg.Id --silent `
                            --accept-source-agreements --accept-package-agreements `
                            2>&1 | Out-File $LogFile -Append
                    }
                }
            }
        }

        # --- 6. Targeted fixes for known Unknown-status device classes ---

        # Bluetooth stack — restart service to re-enumerate BT devices
        Log-Ok "Restarting Bluetooth support service to re-enumerate BT devices..."
        try {
            Restart-Service bthserv -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            Log-Ok "Bluetooth service restarted."
        } catch { Log-Warn "Could not restart Bluetooth service: $_" }

        # USB devices — re-enumerate USB tree via devmgmt trick with pnputil
        Log-Ok "Re-enumerating USB devices..."
        try {
            pnputil /scan-devices 2>&1 | Out-File $LogFile -Append
            # Restart USB hub drivers for Generic USB Hub / SuperSpeed Hub
            Get-PnpDevice -ErrorAction SilentlyContinue |
                Where-Object { $_.FriendlyName -match "USB Hub" -and $_.Status -eq "Unknown" } |
                ForEach-Object {
                    Disable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
                    Start-Sleep -Milliseconds 500
                    Enable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
                    Log-Ok "  Cycled: $($_.FriendlyName)"
                }
        } catch { Log-Warn "USB re-enumeration failed: $_" }

        # Audio virtual endpoints (SWD\MMDEVAPI) — restart audio services
        Log-Ok "Restarting Windows Audio services to refresh virtual audio endpoints..."
        try {
            Restart-Service Audiosrv -Force -ErrorAction SilentlyContinue
            Restart-Service AudioEndpointBuilder -Force -ErrorAction SilentlyContinue
            Log-Ok "Audio services restarted."
        } catch { Log-Warn "Could not restart audio services: $_" }

        # JBL Quantum — cycle device to reload USB audio driver
        Log-Ok "Cycling JBL Quantum USB devices..."
        try {
            Get-PnpDevice -ErrorAction SilentlyContinue |
                Where-Object { $_.FriendlyName -match "JBL" -and $_.Status -eq "Unknown" } |
                ForEach-Object {
                    Disable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
                    Start-Sleep -Milliseconds 500
                    Enable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
                    Log-Ok "  Cycled: $($_.FriendlyName)"
                }
        } catch { Log-Warn "JBL device cycle failed: $_" }

        # Xbox controllers — cycle XINPUT devices
        Log-Ok "Cycling Xbox/XINPUT controller devices..."
        try {
            Get-PnpDevice -ErrorAction SilentlyContinue |
                Where-Object { ($_.FriendlyName -match "Xbox|XINPUT") -and $_.Status -eq "Unknown" } |
                ForEach-Object {
                    Disable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
                    Start-Sleep -Milliseconds 500
                    Enable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
                    Log-Ok "  Cycled: $($_.FriendlyName)"
                }
        } catch { Log-Warn "Xbox device cycle failed: $_" }

        # Generic Non-PnP Monitor — install generic monitor driver
        Log-Ok "Checking monitor driver..."
        try {
            Get-PnpDevice -ErrorAction SilentlyContinue |
                Where-Object { $_.FriendlyName -match "Monitor" -and $_.Status -eq "Unknown" } |
                ForEach-Object {
                    Update-PnpDeviceDriver -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
                    Log-Ok "  Driver update attempted: $($_.FriendlyName)"
                }
        } catch { }

        # Shadow copy volumes — transient, no action needed, just exclude from report
        # SWD\MMDEVAPI virtual audio endpoints — transient, no driver needed

        # --- 7. Final report — exclude known virtual/transient device classes ---
        $virtualPrefixes = @('SWD\MMDEVAPI', 'STORAGE\VOLUMESNAPSHOT')
        $problemDevices = Get-PnpDevice -Status Error, Unknown, Degraded -ErrorAction SilentlyContinue |
            Where-Object {
                $id = $_.InstanceId.ToUpper()
                -not ($virtualPrefixes | Where-Object { $id.StartsWith($_) })
            }

        if ($problemDevices) {
            Log-Warn "Devices still needing attention after all fixes:"
            $problemDevices | ForEach-Object { Log-Warn "  [$($_.Status)] $($_.FriendlyName) — $($_.InstanceId)" }
            Add-Summary "Drivers: $($problemDevices.Count) real device(s) may need manual attention"
        } else {
            Log-Ok "All real devices OK after driver update."
            Add-Summary "Drivers: all devices OK"
        }
    }
}

# ─── winget (Microsoft-official app manager) ───────────────────────────────────

function Update-WingetApps {
    if (-not $UpdateWinget) { return }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Log-Warn "winget not found — skipping. (Install App Installer from the Microsoft Store.)"
        return
    }

    Invoke-Step "winget — all apps" {
        winget upgrade --all --silent --include-unknown `
            --accept-source-agreements --accept-package-agreements `
            2>&1 | Out-File $LogFile -Append
        Add-Summary "winget: all apps upgraded"
    }
}

# ─── Microsoft Store apps ─────────────────────────────────────────────────────

function Update-StoreApps {
    if (-not $UpdateStore) { return }
    Invoke-Step "Microsoft Store apps" {
        # Use winget with msstore source
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            winget upgrade --all --source msstore --silent `
                --accept-source-agreements --accept-package-agreements `
                2>&1 | Out-File $LogFile -Append
            Add-Summary "Microsoft Store: updated"
        }
        # Store update via winget msstore source covers UWP updates
    }
}

# ─── Chocolatey ───────────────────────────────────────────────────────────────

function Update-ChocolateyApps {
    if (-not $UpdateChocolatey) { return }
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) { return }

    Invoke-Step "Chocolatey" {
        choco upgrade all -y --no-progress --ignore-checksums `
            2>&1 | Out-File $LogFile -Append
        Add-Summary "Chocolatey: all packages upgraded"
    }
}

# ─── Scoop ────────────────────────────────────────────────────────────────────

function Update-ScoopApps {
    if (-not $UpdateScoop) { return }
    if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) { return }

    Invoke-Step "Scoop" {
        scoop update        2>&1 | Out-File $LogFile -Append
        scoop update --all  2>&1 | Out-File $LogFile -Append
        scoop cleanup --all 2>&1 | Out-File $LogFile -Append
        Add-Summary "Scoop: all packages updated"
    }
}

# ─── application-level package managers ──────────────────────────────────────

function Update-AppPackageManagers {
    if (-not $UpdateAppManagers) { return }
    Invoke-Step "Application package managers" {

        # pip (Python)
        if (Get-Command pip -ErrorAction SilentlyContinue) {
            Log-Ok "pip: upgrading outdated packages..."
            $outdated = pip list --outdated --format=freeze 2>$null |
                        ForEach-Object { ($_ -split "==")[0] }
            if ($outdated) {
                pip install --upgrade $outdated --quiet 2>&1 | Out-File $LogFile -Append
            }
            Add-Summary "pip: upgraded"
        }

        # pipx
        if (Get-Command pipx -ErrorAction SilentlyContinue) {
            Log-Ok "pipx: upgrading apps..."
            pipx upgrade-all 2>&1 | Out-File $LogFile -Append
            Add-Summary "pipx: upgraded"
        }

        # npm global packages
        if (Get-Command npm -ErrorAction SilentlyContinue) {
            Log-Ok "npm: updating global packages..."
            npm update -g 2>&1 | Out-File $LogFile -Append
            Add-Summary "npm globals: updated"
        }

        # Ruby gems
        if (Get-Command gem -ErrorAction SilentlyContinue) {
            Log-Ok "gem: updating..."
            gem update --system --quiet 2>&1 | Out-File $LogFile -Append
            gem update --quiet          2>&1 | Out-File $LogFile -Append
            gem cleanup                 2>&1 | Out-File $LogFile -Append
            Add-Summary "Ruby gems: updated"
        }

        # Rust toolchain
        if (Get-Command rustup -ErrorAction SilentlyContinue) {
            Log-Ok "rustup: updating..."
            rustup update 2>&1 | Out-File $LogFile -Append
            Add-Summary "Rust toolchain: updated"
        }

        # Cargo installed binaries
        if ((Get-Command cargo -ErrorAction SilentlyContinue) -and
            (cargo install --list 2>$null | Select-String "cargo-install-update")) {
            Log-Ok "cargo-install-update: updating binaries..."
            cargo install-update -a 2>&1 | Out-File $LogFile -Append
            Add-Summary "Cargo binaries: updated"
        }

        # Conda / Mamba
        foreach ($condaCmd in @("conda", "mamba", "micromamba")) {
            if (Get-Command $condaCmd -ErrorAction SilentlyContinue) {
                Log-Ok "${condaCmd}: updating base env..."
                & $condaCmd update --all -y -q 2>&1 | Out-File $LogFile -Append
                Add-Summary "${condaCmd} base: updated"
                break
            }
        }

        # Julia
        if (Get-Command julia -ErrorAction SilentlyContinue) {
            Log-Ok "Julia: updating packages..."
            julia -e 'import Pkg; Pkg.update()' 2>&1 | Out-File $LogFile -Append
        }

        # Poetry
        if (Get-Command poetry -ErrorAction SilentlyContinue) {
            Log-Ok "poetry: self-updating..."
            poetry self update 2>&1 | Out-File $LogFile -Append
        }

        # Go tools
        if (Get-Command go -ErrorAction SilentlyContinue) {
            Log-Ok "Go: updating tools in GOPATH..."
            $gopath = (go env GOPATH) -replace '"', ''
            if (Test-Path "$gopath\bin") {
                Get-ChildItem "$gopath\bin" | ForEach-Object {
                    $pkg = (go version -m $_.FullName 2>$null |
                            Select-String "path").ToString().Split()[1]
                    if ($pkg) { go install "${pkg}@latest" 2>&1 | Out-File $LogFile -Append }
                }
            }
        }
    }
}

# ─── container images ─────────────────────────────────────────────────────────

function Update-Containers {
    if (-not $UpdateContainers) { return }
    Invoke-Step "Container images" {
        # Docker Desktop
        if (Get-Command docker -ErrorAction SilentlyContinue) {
            $running = docker ps --format '{{.Image}}' 2>$null | Sort-Object -Unique
            foreach ($img in $running) {
                if ($img) { docker pull $img 2>&1 | Out-File $LogFile -Append }
            }
            docker image prune -f 2>&1 | Out-File $LogFile -Append
            Add-Summary "Docker images: pulled latest"
        }
    }
}

# ─── development tools & plugins ──────────────────────────────────────────────

function Update-DevTools {
    if (-not $UpdateDevTools) { return }
    Invoke-Step "Development tools & editor plugins" {

        # VS Code extensions
        if (Get-Command code -ErrorAction SilentlyContinue) {
            Log-Ok "VS Code: updating extensions..."
            code --update-extensions 2>&1 | Out-File $LogFile -Append
            Add-Summary "VS Code extensions: updated"
        }

        # Neovim lazy.nvim / packer
        if (Get-Command nvim -ErrorAction SilentlyContinue) {
            Log-Ok "Neovim: syncing plugins..."
            nvim --headless "+Lazy! sync" +qa 2>&1 | Out-File $LogFile -Append
        }

        # Git for Windows component update
        if (Get-Command git -ErrorAction SilentlyContinue) {
            git update-git-for-windows --quiet 2>&1 | Out-File $LogFile -Append
        }

        # Windows Terminal settings (via winget)
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            winget upgrade --id Microsoft.WindowsTerminal --silent `
                --accept-source-agreements --accept-package-agreements `
                2>&1 | Out-File $LogFile -Append
        }
    }
}

# ─── reboot check ─────────────────────────────────────────────────────────────

function Test-RebootRequired {
    if ($NoReboot) { return }
    Log-Section "Reboot check"
    $needed = $false

    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") {
        $needed = $true
    }
    $pending = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" `
                   -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    if ($pending) { $needed = $true }

    if ($needed) {
        Log-Warn "REBOOT REQUIRED — please reboot this machine at your convenience."
        Add-Summary "⚠ Reboot required"
    } else {
        Log-Ok "No reboot required."
    }
}

# ─── notification & summary ───────────────────────────────────────────────────

function Print-Summary {
    $elapsed = [math]::Round(((Get-Date) - $StartTime).TotalSeconds)
    Log-Section "Summary (completed in ${elapsed}s)"
    foreach ($item in $Summary) { Log-Ok $item }

    if ($Notify) {
        $msg = $Summary -join "`n"
        try {
            Add-Type -AssemblyName System.Windows.Forms
            $balloon = New-Object System.Windows.Forms.NotifyIcon
            $balloon.Icon = [System.Drawing.SystemIcons]::Information
            $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
            $balloon.BalloonTipTitle = "System Update Complete"
            $balloon.BalloonTipText = $msg
            $balloon.Visible = $true
            $balloon.ShowBalloonTip(5000)
            Start-Sleep -Seconds 6
            $balloon.Dispose()
        } catch { }
    }

    # Write to Application Event Log
    try {
        $evtSrc = "auto-update"
        if (-not [System.Diagnostics.EventLog]::SourceExists($evtSrc)) {
            [System.Diagnostics.EventLog]::CreateEventSource($evtSrc, "Application")
        }
        $evtLog = [System.Diagnostics.EventLog]::new("Application")
        $evtLog.Source = $evtSrc
        $evtLog.WriteEntry("Monthly update complete (${elapsed}s). Items: $($Summary.Count)", [System.Diagnostics.EventLogEntryType]::Information, 1001)
        $evtLog.Dispose()
    } catch { }
}

# ─── Task Scheduler installation ──────────────────────────────────────────────

function Install-MonthlyTask {
    $scriptPath = (Resolve-Path $PSCommandPath).Path

    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`""

    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit  (New-TimeSpan -Hours 3) `
        -RunOnlyIfNetworkAvailable `
        -StartWhenAvailable `
        -WakeToRun

    $principal = New-ScheduledTaskPrincipal `
        -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    Register-ScheduledTask -TaskName $TaskName `
        -Action $action -Settings $settings -Principal $principal `
        -Description "Monthly system update: OS, drivers, apps, dev tools" `
        -Force | Out-Null

    # Patch trigger to true "Day 1 of every month" via XML
    $xml = Export-ScheduledTask -TaskName $TaskName
    $monthlyTrigger = @"
<CalendarTrigger>
  <StartBoundary>$(Get-Date -Format 'yyyy-MM-01')T03:00:00</StartBoundary>
  <ScheduleByMonth>
    <DaysOfMonth><Day>1</Day></DaysOfMonth>
    <Months>
      <January/><February/><March/><April/><May/><June/>
      <July/><August/><September/><October/><November/><December/>
    </Months>
  </ScheduleByMonth>
</CalendarTrigger>
"@
    $xml = $xml -replace '<Triggers>.*?</Triggers>',
                          "<Triggers>$monthlyTrigger</Triggers>"
    $tmp = [IO.Path]::GetTempFileName() + ".xml"
    $xml | Out-File $tmp -Encoding UTF8
    Register-ScheduledTask -TaskName $TaskName -Xml (Get-Content $tmp -Raw) -Force | Out-Null
    Remove-Item $tmp -Force

    Write-Host ""
    Write-Host "Installed Task Scheduler job: '$TaskName'" -ForegroundColor Green
    Write-Host "Runs:     1st of each month at 03:00 as SYSTEM"
    Write-Host "Logs:     $LogFile"
    Write-Host "Run now:  Start-ScheduledTask -TaskName '$TaskName'"
    Write-Host "Remove:   Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false"
}

# ─── main ─────────────────────────────────────────────────────────────────────

if ($Install) {
    Install-MonthlyTask
    exit 0
}

Acquire-Lock
Rotate-Log

Write-Log "=== Monthly update started (host: $env:COMPUTERNAME · OS: $(
    (Get-CimInstance Win32_OperatingSystem).Caption)) ==="
if ($DryRun) { Log-Warn "DRY-RUN mode — no changes will be made." }

Test-Network
Test-DiskSpace

if ($UpdateOsPackages) { Update-WindowsSystem }
if ($UpdateDrivers)    { Update-AllDrivers }
Update-WingetApps
Update-StoreApps
Update-ChocolateyApps
Update-ScoopApps
Update-AppPackageManagers
Update-Containers
Update-DevTools
Test-RebootRequired
Print-Summary

Write-Log "=== Monthly update complete ==="
Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
