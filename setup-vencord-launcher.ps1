[CmdletBinding()]
param(
    [ValidateSet('Install', 'ConfigureShortcut', 'Launch', 'Run', 'Check')]
    [string]$Mode = 'Check'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$taskName = 'DeviceSetup-VencordRepair'
# Outside AppData: packaged terminals may virtualize AppData writes, making
# them invisible to Task Scheduler's ordinary user process.
$dataDir = Join-Path $env:USERPROFILE '.device-setup\VencordRepair'
$installedScript = Join-Path $dataDir 'setup-vencord-launcher.ps1'
$discordDir = Join-Path $env:LOCALAPPDATA 'Discord'
$patcherPath = Join-Path $env:APPDATA 'Vencord\dist\patcher.js'

function Get-PatchState {
    # Match the official installer's selection of the newest app directory.
    $app = Get-ChildItem -LiteralPath $discordDir -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'resources\app.asar') } |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $app) { throw 'Discord Stable is not installed.' }
    $asar = Join-Path $app.FullName 'resources\app.asar'
    $backup = Join-Path $app.FullName 'resources\_app.asar'
    $patched = $false
    if ((Test-Path -LiteralPath $backup) -and (Test-Path -LiteralPath $patcherPath)) {
        # The injected ASAR is a tiny loader; the original is several megabytes.
        if ((Get-Item -LiteralPath $asar).Length -lt 65536) {
            $patched = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($asar)).Contains('patcher.js')
        }
    }
    [pscustomobject]@{ Version = $app.Name; Patched = $patched; Asar = $asar }
}

function Write-RepairLog([string]$Message) {
    Add-Content -LiteralPath (Join-Path $dataDir 'repair.log') -Encoding UTF8 -Value "$(Get-Date -Format o) $Message"
}

function Invoke-QuietProcess([string]$FilePath, [string]$Arguments, [string]$LogName, [int]$TimeoutSeconds = 120) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $FilePath
    $info.Arguments = $Arguments
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
            throw "$LogName timed out."
        }
        [IO.File]::WriteAllText((Join-Path $dataDir "$LogName.stdout.log"), $stdout.GetAwaiter().GetResult())
        [IO.File]::WriteAllText((Join-Path $dataDir "$LogName.stderr.log"), $stderr.GetAwaiter().GetResult())
        return $process.ExitCode
    } finally { $process.Dispose() }
}

function Get-RepairInstaller {
    $path = Join-Path $dataDir 'VencordInstallerCli.exe'
    $hashPath = "$path.sha256"
    if ((Test-Path -LiteralPath $path) -and (Test-Path -LiteralPath $hashPath)) {
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq (Get-Content -LiteralPath $hashPath -Raw).Trim()) { return $path }
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $release = Invoke-RestMethod -UseBasicParsing -Uri 'https://api.github.com/repos/Vencord/Installer/releases/latest' -TimeoutSec 30
    $asset = $release.assets | Where-Object name -eq 'VencordInstallerCli.exe'
    if ($asset.digest -notmatch '^sha256:([a-f0-9]{64})$') { throw 'Missing official installer SHA256 digest.' }
    $expectedHash = $Matches[1]
    $downloadPath = "$path.download"
    try {
        $curl = Join-Path $env:WINDIR 'System32\curl.exe'
        $curlArgs = @('--fail', '--location', '--silent', '--show-error', '--connect-timeout', '10', '--max-time', '25', '--output', "`"$downloadPath`"", $asset.browser_download_url)
        $downloadCode = Invoke-QuietProcess $curl ($curlArgs -join ' ') 'download'
        if ($downloadCode -ne 0) {
            # Alternate GitHub CDN endpoint for networks where the default edge stalls.
            # TLS hostname verification remains enabled; no system DNS settings change.
            $curlArgs = @('--fail', '--location', '--silent', '--show-error', '--connect-timeout', '10', '--max-time', '60', '--resolve', 'release-assets.githubusercontent.com:443:185.199.108.133', '--output', "`"$downloadPath`"", $asset.browser_download_url)
            $downloadCode = Invoke-QuietProcess $curl ($curlArgs -join ' ') 'download'
            if ($downloadCode -ne 0) { throw 'Could not download the official Vencord installer.' }
        }
        if ((Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash -ne $expectedHash) { throw 'Installer SHA256 mismatch.' }
        Move-Item -LiteralPath $downloadPath -Destination $path -Force
        Set-Content -LiteralPath $hashPath -Value $expectedHash -Encoding ASCII
    } finally {
        Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
    }
    return $path
}

if ($Mode -eq 'Check') {
    Get-PatchState
    return
}

if ($Mode -eq 'ConfigureShortcut') {
    try {
        $pin = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Discord.lnk'
        if (-not (Test-Path -LiteralPath $pin)) { throw 'Pinned Discord shortcut not found.' }
        $backup = Join-Path $dataDir 'Discord.original.lnk'
        if (-not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $pin -Destination $backup }
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut($pin)
        $link.TargetPath = Join-Path $dataDir 'VencordRepairLauncher.exe'
        $link.Arguments = ''
        $link.WorkingDirectory = $dataDir
        $link.IconLocation = (Join-Path $discordDir 'app.ico') + ',0'
        $link.Description = 'Discord with Vencord repair at launch'
        $link.Save()
        $check = $shell.CreateShortcut($pin)
        if ($check.TargetPath -ne (Join-Path $dataDir 'VencordRepairLauncher.exe')) { throw 'Shortcut verification failed.' }
        @{ Success = $true; Shortcut = $pin; Target = $check.TargetPath } | ConvertTo-Json | Set-Content (Join-Path $dataDir 'shortcut-setup.json')
        exit 0
    } catch {
        @{ Success = $false; Error = $_.Exception.Message } | ConvertTo-Json | Set-Content (Join-Path $dataDir 'shortcut-setup.json')
        exit 1
    }
}

if ($Mode -eq 'Install') {
    $null = Get-PatchState
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
    $null = Get-RepairInstaller
    if ([IO.Path]::GetFullPath($PSCommandPath) -ne [IO.Path]::GetFullPath($installedScript)) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $installedScript -Force
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'vencord-launcher.cs') -Destination $dataDir -Force
    }
    # -WindowStyle Hidden on powershell.exe hides an already-created console,
    # which can flash or open Windows Terminal. Start through a GUI executable
    # that creates PowerShell with CREATE_NO_WINDOW instead.
    $launcherPath = Join-Path $dataDir 'VencordRepairLauncher.exe'
    $buildPath = Join-Path $dataDir ('launcher-' + [guid]::NewGuid().ToString('N') + '.exe')
    try {
        Add-Type -Path (Join-Path $dataDir 'vencord-launcher.cs') -OutputAssembly $buildPath -OutputType WindowsApplication
        Move-Item -LiteralPath $buildPath -Destination $launcherPath -Force
    } finally {
        Remove-Item -LiteralPath $buildPath -ErrorAction SilentlyContinue
    }
    $userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    # A one-time native process edits the real AppData shortcut outside any
    # packaged-terminal virtualization. No scheduled task remains after setup.
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    $setupTask = 'DeviceSetup-VencordShortcutSetup'
    $resultPath = Join-Path $dataDir 'shortcut-setup.json'
    Remove-Item -LiteralPath $resultPath -ErrorAction SilentlyContinue
    $action = New-ScheduledTaskAction -Execute $launcherPath -Argument '--setup'
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
    try {
        Register-ScheduledTask -TaskName $setupTask -Action $action -Settings $settings -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName $setupTask
        $deadline = (Get-Date).AddSeconds(30)
        while (-not (Test-Path -LiteralPath $resultPath) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
        if (-not (Test-Path -LiteralPath $resultPath)) { throw 'Shortcut setup timed out.' }
        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        if (-not $result.Success) { throw $result.Error }
    } finally {
        Unregister-ScheduledTask -TaskName $setupTask -Confirm:$false -ErrorAction SilentlyContinue
    }
    Write-Host 'Discord taskbar shortcut updated. Periodic checks removed.'
    return
}

function Test-DiscordUpdating {
    return [bool](Get-Process -Name Update -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq (Join-Path $discordDir 'Update.exe') })
}

function Open-Discord {
    $state = Get-PatchState
    $exe = Join-Path (Split-Path (Split-Path $state.Asar)) 'Discord.exe'
    # Launch the patched version directly. Discord still performs its own
    # normal update check, handled by the bounded startup check below.
    Start-Process -FilePath $exe
}

function Repair-Vencord {
    $state = Get-PatchState
    if ($state.Patched) { return }
    if (Test-DiscordUpdating) { return }

    $logPath = Join-Path $dataDir 'repair.log'
    if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 1MB) {
        Move-Item -LiteralPath $logPath -Destination "$logPath.old" -Force
    }
    Write-RepairLog "Missing Vencord in $($state.Version); restoring injection."
    foreach ($file in @('patcher.js', 'preload.js', 'renderer.js', 'renderer.css')) {
        if (-not (Test-Path -LiteralPath (Join-Path (Split-Path $patcherPath) $file))) {
            throw 'Vencord files are missing. Run install-vencord.ps1 first.'
        }
    }
    $installerPath = Get-RepairInstaller

    # A download can take time. Recheck before allowing the installer to close Discord.
    if ((Get-PatchState).Patched) { return }
    if (Test-DiscordUpdating) { return }
    $wasRunning = @(Get-Process -Name Discord -ErrorAction SilentlyContinue).Count -gt 0
    $previousDevInstall = $env:VENCORD_DEV_INSTALL
    try {
        # Reuse the installed build so repair also works offline. Vencord's own
        # updater handles build updates after Discord loads the mod again.
        $env:VENCORD_DEV_INSTALL = '1'
        $installerCode = Invoke-QuietProcess $installerPath '-install -branch stable' 'installer'
        if ($installerCode -ne 0) { throw "Installer exit code: $installerCode." }
        $after = Get-PatchState
        if (-not $after.Patched) { throw 'Installer finished, but Vencord injection was not found.' }
        Write-RepairLog "Repaired $($after.Version)."
    } finally {
        $env:VENCORD_DEV_INSTALL = $previousDevInstall
        if ($wasRunning -and $Mode -ne 'Launch') { Open-Discord }
    }
}

New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
$mutex = New-Object Threading.Mutex($false, 'Local\DeviceSetup-VencordRepair')
$locked = $false
$exitCode = 0
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { return }
    if ($Mode -eq 'Launch') {
        Write-RepairLog 'Shortcut launch started.'
        $waitUntil = (Get-Date).AddSeconds(60)
        while ((Test-DiscordUpdating) -and (Get-Date) -lt $waitUntil) { Start-Sleep -Seconds 2 }
        Repair-Vencord
        Open-Discord
        # Only this launch is observed, for at most 60 seconds. A Discord update
        # during startup can replace the loader after the initial repair.
        $deadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            if (Test-DiscordUpdating) { continue }
            if (-not (Get-Process Discord -ErrorAction SilentlyContinue)) { break }
            $current = Get-PatchState
            if (-not $current.Patched -and (Get-Item -LiteralPath $current.Asar).LastWriteTime -lt (Get-Date).AddSeconds(-5)) {
                Repair-Vencord
                Open-Discord
            }
        }
        Write-RepairLog 'Shortcut launch finished; no background watcher remains.'
    } else { Repair-Vencord }
} catch {
    Write-RepairLog "ERROR: $($_.Exception.Message)"
    if ($Mode -eq 'Launch') {
        # A repair/network failure must not prevent using Discord itself.
        try { Open-Discord } catch { Write-RepairLog "Could not open Discord: $($_.Exception.Message)" }
    }
    $exitCode = 1
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
exit $exitCode
