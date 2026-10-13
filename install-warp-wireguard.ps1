param(
    [Parameter(Mandatory)][string]$AccountPath,
    [Parameter(Mandatory)][string]$WireGuardConfigPath,
    [Parameter(Mandatory)][string]$UsquePath,
    [Parameter(Mandatory)][string]$SingBoxPath,
    [string]$InstallDirectory = "$env:USERPROFILE\.device-setup\warp-wireguard",
    [string]$PreferredInterface = 'Ethernet',
    [string]$WarpEndpoint = '162.159.198.2',
    [string]$Server = '92.246.139.113',
    [int]$ServerPort = 51871
)
$ErrorActionPreference = 'Stop'
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {throw 'Run installer as administrator to register the login task.'}
$taskName = 'DeviceSetup WARP WireGuard'
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {throw 'Task already exists; inspect the installed service before updating.'}
if (Test-Path -LiteralPath $InstallDirectory) {throw 'Installation directory exists; choose a fresh directory or inspect the previous installation.'}
$python = (Get-Command python.exe).Source
$pythonw = Join-Path (Split-Path $python) 'pythonw.exe'
foreach ($file in @($pythonw,$AccountPath,$WireGuardConfigPath,$UsquePath,$SingBoxPath)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {throw "Missing file: $file"}
}
$account = Get-Content -LiteralPath $AccountPath -Raw | ConvertFrom-Json
$config = Get-Content -LiteralPath $WireGuardConfigPath -Raw | ConvertFrom-Json
if (-not ($config.inbounds | Where-Object {$_.listen -eq '127.0.0.1' -and $_.listen_port -eq 19506})) {
    throw 'Expected existing loopback WireGuard profile on 19506.'
}
New-Item -ItemType Directory -Path $InstallDirectory | Out-Null
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
& icacls.exe $InstallDirectory /inheritance:r /grant:r "*${sid}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE) {throw 'Could not restrict installation directory permissions.'}
Copy-Item -LiteralPath $UsquePath -Destination (Join-Path $InstallDirectory 'usque.exe')
Copy-Item -LiteralPath $SingBoxPath -Destination (Join-Path $InstallDirectory 'sing-box.exe')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'warp-wireguard.py') -Destination $InstallDirectory
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'warp-bridge.py') -Destination (Join-Path $InstallDirectory 'warp-support.py')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'experiments\socks-udp-relay.py') -Destination $InstallDirectory
$account.endpoint_v4 = '127.0.0.1'
if ($account.PSObject.Properties.Name -contains 'endpoint_h2_v4') {$account.endpoint_h2_v4='127.0.0.1'}
$utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText((Join-Path $InstallDirectory 'account.json'), ($account | ConvertTo-Json -Depth 30), $utf8)
$config.log.level = 'warn'
[IO.File]::WriteAllText((Join-Path $InstallDirectory 'wireguard.json'), ($config | ConvertTo-Json -Depth 50), $utf8)
$transportSettings = @{preferred_interface=$PreferredInterface;warp_endpoint=$WarpEndpoint;relay_port=19502;warp_socks_port=19501;
    wg_relay_port=19505;socks_port=19506;server=$Server;server_port=$ServerPort} |
    ConvertTo-Json
[IO.File]::WriteAllText((Join-Path $InstallDirectory 'settings.json'), $transportSettings, $utf8)
# The supervisor resolves every path relative to __file__; no scheduler working directory is needed.
$action = New-ScheduledTaskAction -Execute $pythonw -Argument ('"{0}"' -f (Join-Path $InstallDirectory 'warp-wireguard.py'))
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
$taskPrincipal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $taskPrincipal `
    -Description 'Persistent local WARP to WireGuard transport for v2rayN; reconnects after network changes.' | Out-Null
Write-Output "Installed $taskName. Stop the old transport safely, then Start-ScheduledTask -TaskName '$taskName'."
