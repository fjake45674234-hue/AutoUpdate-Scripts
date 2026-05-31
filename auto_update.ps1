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
        $pid = Get-Content $LockFile -ErrorAction SilentlyContinue
        $proc = Get-Process -Id $pid -ErrorAction SilentlyContinue
        if ($proc) {
            Log-Error "Another update is running (PID $pid). Aborting."
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

# ─── GPU / hardware drivers ───────────────────────────────────────────────────

function Update-GpuDrivers {
    Invoke-Step "GPU & hardware drivers" {
        $driverPkgs = @(
            @{ Id="Nvidia.GeForceExperience";                  Name="NVIDIA GeForce Experience"     },
            @{ Id="Nvidia.CUDA";                               Name="NVIDIA CUDA Toolkit"           },
            @{ Id="Intel.IntelDriverAndSupportAssistant";      Name="Intel Driver Support Assistant"},
            @{ Id="AdvancedMicroDevices.AMDSoftware";          Name="AMD Software Adrenalin"        },
            @{ Id="Intel.IntelArcControlApp";                  Name="Intel Arc Control"             },
            @{ Id="Realtek.RealtekAudioControl";               Name="Realtek Audio Control"         }
        )

        foreach ($pkg in $driverPkgs) {
            $installed = winget list --id $pkg.Id 2>&1
            if ($installed -match [regex]::Escape($pkg.Id)) {
                Log-Ok "Upgrading $($pkg.Name)..."
                winget upgrade --id $pkg.Id --silent `
                    --accept-source-agreements --accept-package-agreements `
                    2>&1 | Out-File $LogFile -Append
            }
        }

        # Windows Update already covers signed driver updates (done above)
        Add-Summary "GPU/hardware drivers: checked"
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
        # Also trigger UWP store updates via COM
        try {
            $storeUpdate = [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallManager,
                Windows.ApplicationModel.Store.Preview, ContentType=WindowsRuntime]::new()
            $storeUpdate.UpdateAppByPackageFamilyNameAsync("") | Out-Null
        } catch { }
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
        [Windows.UI.Notifications.ToastNotificationManager,
         Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null
        $xml = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument,
                ContentType=WindowsRuntime]::new()
        $xml.LoadXml("<toast><visual><binding template='ToastGeneric'>" +
                     "<text>System Update Complete</text>" +
                     "<text>$msg</text></binding></visual></toast>")
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("auto-update").Show($toast)
    }

    # Write to Application Event Log
    Write-EventLog -LogName Application -Source "auto-update" -EventId 1001 `
        -EntryType Information `
        -Message "Monthly update complete (${elapsed}s). Items: $($Summary.Count)" `
        -ErrorAction SilentlyContinue
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
if ($UpdateDrivers)    { Update-GpuDrivers }
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
