# Run as the same Windows user, with administrator rights for legacy tasks/firewall.
[CmdletBinding()]
param(
    [switch]$RetireLegacy,
    [switch]$CheckMinecraft,
    [switch]$CheckTunnel,
    [string]$PublicAddress,
    [string]$ProbeAddress,
    [string]$SshHost = 'test'
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$guiRoot = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev'
$legacyRoot = Join-Path $env:USERPROFILE '.device-setup\warp-wireguard'
$stateRoot = Join-Path $env:USERPROFILE ('.device-setup\mihomo-trial\maintenance-' + (Get-Date -Format yyyyMMdd-HHmmss))
New-Item -ItemType Directory -Path $stateRoot | Out-Null
$result = [ordered]@{ backup = $stateRoot }
$proxyKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

function Assert-Clash {
    $proxy = Get-ItemProperty $proxyKey
    if ($proxy.ProxyEnable -ne 1 -or $proxy.ProxyServer -ne '127.0.0.1:7897') { throw 'Expected active Clash system proxy on port 7897' }
    if (-not (Get-NetAdapter -Name 'mihomo-trial' -ErrorAction SilentlyContinue | Where-Object Status -eq Up)) { throw 'Clash TUN is not up' }
    $status = & curl.exe --silent --show-error --max-time 15 --proxy http://127.0.0.1:7897 -o NUL -w '%{http_code}' https://api.openai.com/v1/models
    if ($LASTEXITCODE -ne 0 -or $status -ne '401') { throw 'Clash VPN connectivity check failed' }
}

function Restore-ClashProxy {
    # v2rayN may clear/change this shared setting as it exits. TUN stays up.
    Set-ItemProperty -LiteralPath $proxyKey -Name ProxyEnable -Value 1
    Set-ItemProperty -LiteralPath $proxyKey -Name ProxyServer -Value '127.0.0.1:7897'
    if (-not ('DeviceSetupProxyNotify' -as [type])) {
        Add-Type 'using System; using System.Runtime.InteropServices; public class DeviceSetupProxyNotify { [DllImport("wininet.dll")] public static extern bool InternetSetOption(IntPtr h, int o, IntPtr b, int n); }'
    }
    [DeviceSetupProxyNotify]::InternetSetOption([IntPtr]::Zero,39,[IntPtr]::Zero,0) | Out-Null
    [DeviceSetupProxyNotify]::InternetSetOption([IntPtr]::Zero,37,[IntPtr]::Zero,0) | Out-Null
}

try {
    Assert-Clash
    if ($RetireLegacy -or $CheckMinecraft) {
        $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run PowerShell as administrator' }
    }
    if ($RetireLegacy) {
        if (-not (Select-String -LiteralPath (Join-Path $guiRoot 'verge.yaml') -Pattern '^enable_auto_launch:\s*true\s*$' -Quiet)) { throw 'Enable Auto Launch in Clash first' }
        $v2rayExe = Join-Path $env:USERPROFILE 'Downloads\v2rayN-windows-64\v2rayN-windows-64\v2rayN.exe'
        $tasks = @(Get-ScheduledTask | Where-Object {
            $_.TaskName -eq 'DeviceSetup WARP WireGuard' -or
            ($_.TaskName -like 'v2rayNAutoRun_*' -and $_.Actions.Execute.Trim('"') -eq $v2rayExe)
        })
        if ($tasks.Count -ne 2) { throw 'Expected exactly the two known legacy tasks' }
        foreach ($task in $tasks) {
            Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath | Set-Content -LiteralPath (Join-Path $stateRoot ($task.TaskName + '.xml')) -Encoding UTF8
        }
        try {
            foreach ($task in $tasks) { $task | Disable-ScheduledTask | Out-Null }
            # The supervisor supports a graceful stop and owns its child processes.
            Set-Content -LiteralPath (Join-Path $legacyRoot 'stop.request') -Value 'migration to Clash'
            $deadline = (Get-Date).AddSeconds(15)
            do {
                $old = @(Get-CimInstance Win32_Process | Where-Object {
                    $_.Name -eq 'pythonw.exe' -and $_.CommandLine -like ('*' + (Join-Path $legacyRoot 'warp-wireguard.py') + '*')
                })
                if (-not $old) { break }
                Start-Sleep -Milliseconds 300
            } while ((Get-Date) -lt $deadline)
            if ($old) { throw 'Legacy supervisor did not stop gracefully; inspect before forcing termination' }
            # Only the identified v2rayN installation and cores in its directory.
            $v2root = Split-Path $v2rayExe -Parent
            $processes = @(Get-CimInstance Win32_Process | Where-Object {
                $_.ExecutablePath -eq $v2rayExe -or
                ($_.Name -in @('xray.exe','sing-box.exe') -and $_.ExecutablePath -like ($v2root + '\*'))
            })
            foreach ($proc in $processes) {
                $current = Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.ProcessId)"
                if ($current -and $current.CreationDate -eq $proc.CreationDate -and $current.ExecutablePath -eq $proc.ExecutablePath) {
                    Stop-Process -Id $proc.ProcessId -ErrorAction Stop
                }
            }
        } finally { Restore-ClashProxy }
        Assert-Clash
        $result.legacy = 'Disabled both scheduled tasks; stopped supervisor and identified v2rayN processes; files retained'
    }
    if ($CheckMinecraft) {
        foreach ($address in @($PublicAddress, $ProbeAddress)) {
            $parsed = $null
            if (-not [Net.IPAddress]::TryParse($address, [ref]$parsed) -or $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'Provide PublicAddress and ProbeAddress as IPv4 addresses' }
        }
        $mapping = (New-Object -ComObject HNetCfg.NATUPnP).StaticPortMappingCollection
        if ($null -eq $mapping) { throw 'UPnP router not found' }
        $localIP = (Get-NetIPConfiguration -InterfaceAlias Ethernet).IPv4Address.IPAddress
        $existing = @($mapping | Where-Object { $_.ExternalPort -eq 25565 -and $_.Protocol -eq 'TCP' })
        if ($existing -and ($existing[0].InternalClient -ne $localIP -or $existing[0].InternalPort -ne 25565 -or -not $existing[0].Enabled)) { throw 'Existing port mapping belongs to another destination or is disabled' }
        $saved = @{}
        foreach ($action in @('Allow','Block')) { foreach ($protocol in @('TCP','UDP')) {
            $name = "Minecraft-Friends-25565-20260928-$action-$protocol"
            $saved[$name] = @((Get-NetFirewallRule -Name $name | Get-NetFirewallAddressFilter).RemoteAddress)
        } }
        $saved | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stateRoot 'minecraft-firewall-before.json')
        $addedMapping = $false
        try {
            & (Join-Path $repoRoot 'add-minecraft-friend.ps1') -IPAddress $ProbeAddress -Confirm:$false
            if (-not $existing) { $mapping.Add(25565,'TCP',25565,$localIP,$true,'DeviceSetup temporary Minecraft verification') | Out-Null; $addedMapping = $true }
            $output = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'experiments\minecraft-status.py') | & ssh.exe -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 $SshHost python3 - $PublicAddress 2>&1
            $code = $LASTEXITCODE
            $output | Set-Content -LiteralPath (Join-Path $stateRoot 'minecraft-external.log')
            $result.minecraft = @{ exitCode=$code; output=($output -join "`n"); temporaryMapping=$addedMapping }
        } finally {
            # Reinstate restrictive block ranges before removing the temporary allow.
            $restoreErrors = @()
            foreach ($action in @('Block','Allow')) { foreach ($protocol in @('TCP','UDP')) {
                $name = "Minecraft-Friends-25565-20260928-$action-$protocol"
                try { Set-NetFirewallRule -Name $name -RemoteAddress $saved[$name] }
                catch { $restoreErrors += "${name}: $_" }
            } }
            if ($addedMapping) {
                try { $mapping.Remove(25565,'TCP') }
                catch { $restoreErrors += "Temporary UPnP mapping: $_" }
            }
            if ($restoreErrors) { throw ('Restore failed; use minecraft-firewall-before.json: ' + ($restoreErrors -join '; ')) }
        }
    }
    if ($CheckTunnel) {
        $port = 19780
        if (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue) { throw 'Test port 19780 is occupied' }
        $publicRoot = Join-Path $stateRoot 'public'
        New-Item -ItemType Directory -Path $publicRoot | Out-Null
        $nonce = 'device-setup-tun-' + [guid]::NewGuid().ToString()
        Set-Content -LiteralPath (Join-Path $publicRoot 'index.html') -Value $nonce -NoNewline -Encoding ASCII
        $httpProcess = $null; $tunnelProcess = $null
        try {
            $httpProcess = Start-Process -FilePath (Get-Command python.exe).Source -ArgumentList @('-m','http.server',"$port",'--bind','127.0.0.1','--directory',('"'+$publicRoot+'"')) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $stateRoot 'http.out.log') -RedirectStandardError (Join-Path $stateRoot 'http.err.log')
            $tunnelLog = Join-Path $stateRoot 'tunnel.err.log'
            $tunnelProcess = Start-Process -FilePath (Get-Command cloudflared.exe).Source -ArgumentList @('tunnel','--no-autoupdate','--protocol','quic','--url',"http://127.0.0.1:$port") -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $stateRoot 'tunnel.out.log') -RedirectStandardError $tunnelLog
            $deadline = (Get-Date).AddSeconds(45); $url = $null
            do {
                Start-Sleep -Milliseconds 500
                $log = Get-Content -Raw -LiteralPath $tunnelLog -ErrorAction SilentlyContinue
                if ($log -match 'https://[a-z0-9-]+\.trycloudflare\.com' -and $log -match 'Registered tunnel connection') { $url = [regex]::Match($log,'https://[a-z0-9-]+\.trycloudflare\.com').Value; break }
                if ($tunnelProcess.HasExited) { throw 'cloudflared exited; inspect tunnel.err.log' }
            } while ((Get-Date) -lt $deadline)
            if (-not $url) { throw 'No registered QUIC tunnel within 45 seconds' }
            $body = & ssh.exe -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 $SshHost curl --noproxy "'*'" --silent --show-error --fail --max-time 20 $url
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($body) -or $body.Trim() -ne $nonce) { throw 'External Cloudflare response did not match the local test page' }
            $result.tunnel = 'External HTTP body verified through a QUIC Cloudflare Tunnel with TUN enabled'
        } finally {
            foreach ($owned in @($tunnelProcess,$httpProcess)) {
                if ($null -ne $owned -and -not $owned.HasExited) { Stop-Process -InputObject $owned }
            }
        }
    }
} catch {
    $result.error = $_.Exception.Message
    Write-Warning $result.error
} finally {
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $stateRoot 'result.json') -Encoding UTF8
    $result | ConvertTo-Json -Depth 6
}
if ($result.error) { exit 1 }
