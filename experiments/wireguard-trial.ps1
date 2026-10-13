param(
    [ValidateSet('Start','Stop','Status')][string]$Action = 'Status',
    [string]$DataDirectory = "$env:LOCALAPPDATA\DeviceSetup\warp-latency-20261013"
)
$ErrorActionPreference = 'Stop'
$statePath = Join-Path $DataDirectory 'wireguard-trial-processes.json'
$state = if (Test-Path -LiteralPath $statePath) { Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json } else { @() }
$alive = @($state | Where-Object {
    $p = Get-Process -Id $_.PID -ErrorAction SilentlyContinue
    $p -and $p.Path -eq $_.Path -and [Math]::Abs(($p.StartTime.ToUniversalTime() - ([datetime]$_.Started).ToUniversalTime()).TotalMilliseconds) -lt 1
})
if ($Action -eq 'Status') { $alive | Select-Object Name,PID,Started; return }
if ($Action -eq 'Stop') {
    # Stop only processes whose executable AND creation timestamp still match.
    [array]::Reverse($alive)
    foreach ($item in $alive) { Stop-Process -Id $item.PID }
    Write-Output 'Local trial stopped. The normal WARP-VLESS mode is independent.'
    return
}
if ($alive.Count -eq 4) { Write-Output 'WireGuard trial already running on 127.0.0.1:19506.'; return }
if ($alive.Count) { throw 'Only part of the trial is running. Run -Action Stop, then -Action Start.' }
foreach ($port in @(19501,19503,19504,19506)) {
    if (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) { throw "TCP port $port is occupied." }
}
foreach ($port in @(19502,19505)) {
    if (Get-NetUDPEndpoint -LocalPort $port -ErrorAction SilentlyContinue) { throw "UDP port $port is occupied." }
}
$python = (Get-Command python.exe).Source
$singbox = "$env:USERPROFILE\Downloads\v2rayN-windows-64\v2rayN-windows-64\bin\sing_box\sing-box.exe"
$usque = "$env:LOCALAPPDATA\DeviceSetup\warp-bridge\usque.exe"
foreach ($file in @($singbox,$usque,(Join-Path $DataDirectory 'physical_proxy.py'),(Join-Path $DataDirectory 'socks-udp-relay.py'),(Join-Path $DataDirectory 'usque-udp-local.json'),(Join-Path $DataDirectory 'wireguard-warp.json'))) {
    if (-not (Test-Path -LiteralPath $file)) { throw "Missing trial file: $file" }
}
$network = Get-NetIPConfiguration -InterfaceAlias 'Ethernet'
$source = $network.IPv4Address.IPAddress | Select-Object -First 1
if (-not $source -or -not $network.IPv4DefaultGateway) { throw 'Ethernet IPv4 connection is unavailable.' }
& ssh -o BatchMode=yes -o ConnectTimeout=10 test 'ip link show wg-codex >/dev/null 2>&1 || bash /opt/warp-wireguard-test/wireguard-server.sh up'
if ($LASTEXITCODE) { throw 'Could not start or verify the isolated server interface.' }
$specs = @(
    @{Name='warp-udp-relay'; Exe=$python; Args="-u `"$DataDirectory\physical_proxy.py`" --source $source --interface $($network.InterfaceIndex) --remote 162.159.198.2 --proxy-port 19503 --tcp-port 19504 --udp-port 19502"},
    @{Name='usque-udp'; Exe=$usque; Args="-c `"$DataDirectory\usque-udp-local.json`" socks -b 127.0.0.1 -p 19501 -P 19502 --always-reconnect --udp-timeout 300s"},
    @{Name='wg-socks-relay'; Exe=$python; Args="-u `"$DataDirectory\socks-udp-relay.py`""},
    @{Name='wireguard-warp'; Exe=$singbox; Args="run -c `"$DataDirectory\wireguard-warp.json`""}
)
$started = @()
try {
    foreach ($spec in $specs) {
        $p = Start-Process -FilePath $spec.Exe -ArgumentList $spec.Args -WindowStyle Hidden -WorkingDirectory $DataDirectory -RedirectStandardOutput (Join-Path $DataDirectory "$($spec.Name)-trial.log") -RedirectStandardError (Join-Path $DataDirectory "$($spec.Name)-trial-error.log") -PassThru
        $started += @{Name=$spec.Name; PID=$p.Id; Path=$p.Path; Started=$p.StartTime.ToUniversalTime().ToString('o')}
        Start-Sleep -Milliseconds 700
        if ($p.HasExited) { throw "$($spec.Name) exited; see its trial log." }
    }
    $started | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding utf8
    Write-Output 'WireGuard trial started: SOCKS 127.0.0.1:19506. This does not change the selected v2rayN profile.'
} catch {
    foreach ($item in $started) {
        $p = Get-Process -Id $item.PID -ErrorAction SilentlyContinue
        if ($p -and $p.StartTime.ToUniversalTime().ToString('o') -eq $item.Started) { Stop-Process -Id $p.Id }
    }
    throw
}
