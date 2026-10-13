param(
    [Parameter(Mandatory)][string]$UsquePath,
    [Parameter(Mandatory)][string]$AccountPath,
    [string]$InstallDirectory = "$env:LOCALAPPDATA\DeviceSetup\warp-bridge",
    [string]$PreferredInterface = 'Ethernet',
    [int]$SocksPort = 19486,
    [int]$RelayPort = 19489
)
$ErrorActionPreference = 'Stop'
$startup = [Environment]::GetFolderPath('Startup')
$startupLink = Join-Path $startup 'DeviceSetup WARP.lnk'
if (Test-Path -LiteralPath $startupLink) {
    throw "Startup shortcut already exists; inspect it before replacing: $startupLink"
}
$python = (Get-Command python.exe).Source
$pythonw = Join-Path (Split-Path $python) 'pythonw.exe'
if (-not (Test-Path -LiteralPath $pythonw)) { throw 'Install Python with pythonw.exe first.' }
if (-not (Test-Path -LiteralPath $UsquePath)) { throw 'usque executable not found.' }
$account = Get-Content -Raw -LiteralPath $AccountPath | ConvertFrom-Json
$endpoint = [string]$account.endpoint_v4
$parsedAddress = $null
if (-not [Net.IPAddress]::TryParse($endpoint, [ref]$parsedAddress) -or $parsedAddress.AddressFamily -ne 'InterNetwork') {
    throw 'The account must contain a valid endpoint_v4 address.'
}
New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'warp-bridge.py') -Destination (Join-Path $InstallDirectory 'warp-bridge.py')
Copy-Item -LiteralPath $UsquePath -Destination (Join-Path $InstallDirectory 'usque.exe')
$account.endpoint_v4 = '127.0.0.1'
if ($account.PSObject.Properties.Name -contains 'endpoint_h2_v4') { $account.endpoint_h2_v4 = '127.0.0.1' }
$account | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $InstallDirectory 'account.json') -Encoding utf8
@{
    usque = Join-Path $InstallDirectory 'usque.exe'
    account = Join-Path $InstallDirectory 'account.json'
    preferred_interface = $PreferredInterface
    endpoint = $endpoint
    socks_port = $SocksPort
    relay_port = $RelayPort
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $InstallDirectory 'bridge-settings.json') -Encoding utf8

# A per-user login shortcut needs no administrator privileges.
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($startupLink)
$shortcut.TargetPath = $pythonw
$shortcut.Arguments = '"' + (Join-Path $InstallDirectory 'warp-bridge.py') + '"'
$shortcut.WorkingDirectory = $InstallDirectory
$shortcut.WindowStyle = 7
$shortcut.Description = 'Physical-interface WARP hop for the Germany via WARP v2rayN profile'
$shortcut.Save()
Copy-Item -LiteralPath $startupLink -Destination (Join-Path $InstallDirectory 'Start WARP.lnk')
@'
$ErrorActionPreference = 'Stop'
New-Item -ItemType File -Path (Join-Path $PSScriptRoot 'stop.request') -Force | Out-Null
Write-Host 'WARP stop requested. Select the original VLESS profile in v2rayN to use the direct connection.'
'@ | Set-Content -LiteralPath (Join-Path $InstallDirectory 'Stop WARP.ps1') -Encoding utf8
Write-Output "Installed at $InstallDirectory. Start with Start WARP.lnk; auto-start is enabled for the next Windows login."
