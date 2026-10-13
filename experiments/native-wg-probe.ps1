param(
    [ValidateSet('Install','Probe','Stop')][string]$Action = 'Probe',
    [Parameter(Mandatory=$true)][string]$DataDirectory,
    [ValidateRange(30,300)][int]$Seconds = 180,
    [string]$CaptureDll,
    [string]$PythonExecutable,
    [ValidateSet('warp','direct')][string]$Transport = 'warp',
    [switch]$CompareRoutes
)
$ErrorActionPreference = 'Stop'
[System.Diagnostics.Process]::GetCurrentProcess().PriorityClass='AboveNormal'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run from an elevated PowerShell.'
}
$DataDirectory = (Resolve-Path -LiteralPath $DataDirectory).Path
$wireguard = Join-Path $env:ProgramFiles 'WireGuard\wireguard.exe'
if ($Action -eq 'Install') {
    if (Test-Path -LiteralPath $wireguard) { throw 'WireGuard is already installed; inspect it before changing it.' }
    $msi = Join-Path $DataDirectory 'wireguard-amd64-1.1.1.msi'
    $signature = Get-AuthenticodeSignature -LiteralPath $msi
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'CN=WireGuard LLC,') {
        throw 'WireGuard installer signature verification failed.'
    }
    if ((Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash -ne '7BFED60AD61B785C914B38B61555A975488E1D3EC472DBFB2FCDF498FCA75242') {
        throw 'Unexpected installer digest.'
    }
    $log = Join-Path $DataDirectory 'install.log'
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart DO_NOT_LAUNCH=1 /L*v `"$log`"" -WindowStyle Hidden -Wait -PassThru
    @{exit_code=$p.ExitCode; installed=(Test-Path -LiteralPath $wireguard)} | ConvertTo-Json | Set-Content (Join-Path $DataDirectory 'install-result.json')
    if ($p.ExitCode -notin @(0,3010)) { throw "MSI failed: $($p.ExitCode); see install.log" }
    return
}
if (-not (Test-Path -LiteralPath $wireguard)) { throw 'Install the verified WireGuard client first.' }
$tunnelName=if($Transport -eq 'warp'){'native-win-probe'}else{'native-win-direct-probe'}
$service='WireGuardTunnel$'+$tunnelName
function Stop-OwnedProbe {
    if(Get-Service -Name $service -ErrorAction SilentlyContinue){
        $svc=Get-CimInstance Win32_Service -Filter "Name='$service'"
        if($svc.PathName -notlike "*$tunnelName.conf*"){throw 'Unexpected service configuration; refusing cleanup'}
        $removed=Start-Process -FilePath $wireguard -ArgumentList "/uninstalltunnelservice $tunnelName" -WindowStyle Hidden -Wait -PassThru
        if($removed.ExitCode -and (Get-Service -Name $service -ErrorAction SilentlyContinue)){throw "Tunnel removal failed: $($removed.ExitCode)"}
        $deadline=(Get-Date).AddSeconds(30)
        while((Get-Service -Name $service -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline){Start-Sleep -Milliseconds 500}
        if(Get-Service -Name $service -ErrorAction SilentlyContinue){throw 'Probe service remains after removal'}
    }
}
if($Action -eq 'Stop'){Stop-OwnedProbe; return}
$config = Join-Path $DataDirectory ($tunnelName+'.conf')
$text = Get-Content -Raw -LiteralPath $config
$endpoint=if($Transport -eq 'warp'){'127.0.0.1:19515'}else{'92.246.139.113:51871'}
foreach ($required in @('Address = 10.203.13.4/32','AllowedIPs = 10.203.13.1/32',"Endpoint = $endpoint",'MTU = 1200')) {
    if (($text -split '\r?\n' | Where-Object { $_ -eq $required }).Count -ne 1) { throw 'Unexpected probe configuration.' }
}
$fields = @($text -split '\r?\n' | Where-Object { $_ -match '=' } | ForEach-Object { ($_ -split '=',2)[0].Trim() })
if (($fields | Sort-Object) -join ',' -ne 'Address,AllowedIPs,Endpoint,MTU,PersistentKeepalive,PrivateKey,PublicKey') {
    throw 'Unexpected extra configuration fields; refusing route/DNS/hooks changes.'
}
if (Get-Service -Name 'WireGuardTunnel$native-win*-probe' -ErrorAction SilentlyContinue) { throw 'Another native probe service already exists.' }
if ($Transport -eq 'warp' -and -not (Get-NetUDPEndpoint -LocalAddress 127.0.0.1 -LocalPort 19515 -ErrorAction SilentlyContinue)) { throw 'Start the separate UDP relay on 19515 first.' }
if($CompareRoutes -and ($Transport -ne 'direct' -or -not $PythonExecutable -or -not (Get-NetUDPEndpoint -LocalAddress 127.0.0.1 -LocalPort 19515 -ErrorAction SilentlyContinue))){throw 'Route comparison requires direct profile, Python, and relay 19515'}
if (Get-NetRoute -AddressFamily IPv4 | Where-Object { $_.DestinationPrefix -match '^10\.203\.13\.' }) { throw 'An existing route conflicts with the probe.' }
$before = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Select-Object InterfaceIndex,NextHop,RouteMetric | Sort-Object InterfaceIndex,NextHop | ConvertTo-Json -Compress)
$started = $false
$capture = $null
try {
    $installed=Start-Process -FilePath $wireguard -ArgumentList "/installtunnelservice `"$config`"" -WindowStyle Hidden -Wait -PassThru
    if ($installed.ExitCode) { throw "Tunnel service installation failed: $($installed.ExitCode)" }
    $started = $true
    $deadline=(Get-Date).AddSeconds(60)
    do {
        $route=Get-NetRoute -DestinationPrefix '10.203.13.1/32' -ErrorAction SilentlyContinue
        if(-not $route){Start-Sleep -Milliseconds 500}
    } until($route -or (Get-Date) -ge $deadline)
    if(-not $route){throw 'Probe route did not appear within 60 seconds'}
    if ($CaptureDll) {
        if (-not $PythonExecutable -or -not (Test-Path -LiteralPath $CaptureDll)) { throw 'Capture requires Python and an existing WinDivert DLL.' }
        $captureScript = Join-Path $DataDirectory 'capture-tun-udp.py'
        $captureDir = Join-Path $DataDirectory ('capture-' + (Get-Date -Format 'HHmmss'))
        $capture = Start-Process -FilePath $PythonExecutable -ArgumentList "`"$captureScript`" --dll `"$CaptureDll`" --output-directory `"$captureDir`" --game-port 19516 --only-ports --seconds $($Seconds-10)" -WindowStyle Hidden -PassThru
        $capture.PriorityClass = 'AboveNormal'
    }
    @{at=(Get-Date).ToString('o'); interface_index=$route.InterfaceIndex; duration_seconds=$Seconds; transport=$Transport} | ConvertTo-Json | Set-Content (Join-Path $DataDirectory 'probe-ready.json')
    if($CompareRoutes){
        $publicKey=($text -split '\r?\n' | Where-Object {$_ -like 'PublicKey = *'}) -replace '^PublicKey = ',''
        $wg=Join-Path $env:ProgramFiles 'WireGuard\wg.exe'
        $phases=@()
        foreach($phase in @('direct-before','warp','direct-after')){
            $remote=if($phase -eq 'warp'){'127.0.0.1:19515'}else{'92.246.139.113:51871'}
            $changed=Start-Process -FilePath $wg -ArgumentList "set $tunnelName peer $publicKey endpoint $remote" -WindowStyle Hidden -Wait -PassThru
            if($changed.ExitCode){throw 'Failed to change the test peer endpoint'}
            $phases+=@{phase=$phase;at=(Get-Date).ToString('o')}
            $phases|ConvertTo-Json|Set-Content (Join-Path $DataDirectory 'route-phases.json')
            $comparison=Join-Path $DataDirectory 'compare-native-wg.py'
            $result=Join-Path $DataDirectory "route-$phase.json"
            $meter=Start-Process -FilePath $PythonExecutable -ArgumentList "`"$comparison`" --seconds 45 --priority above-normal --output `"$result`"" -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $DataDirectory "route-$phase.log") -RedirectStandardError (Join-Path $DataDirectory "route-$phase-error.log")
            if(-not $meter.WaitForExit(75000)){$meter.Kill();$meter.WaitForExit();throw 'Comparison exceeded its time limit'}
            if($meter.ExitCode){throw "Route comparison failed: $phase"}
        }
    }else{Start-Sleep -Seconds $Seconds}
} catch {
    @{error=$_.Exception.Message; at=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content (Join-Path $DataDirectory 'probe-error.json')
    throw
} finally {
    if ($capture -and -not $capture.HasExited) { $capture.Kill(); $capture.WaitForExit() }
    if ($started -or (Get-Service -Name $service -ErrorAction SilentlyContinue)) {
        Stop-OwnedProbe
    }
    $after = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Select-Object InterfaceIndex,NextHop,RouteMetric | Sort-Object InterfaceIndex,NextHop | ConvertTo-Json -Compress)
    @{default_routes_unchanged=($before -join '') -eq ($after -join '');
      service_remaining=[bool](Get-Service -Name $service -ErrorAction SilentlyContinue);
      route_remaining=[bool](Get-NetRoute -DestinationPrefix '10.203.13.1/32' -ErrorAction SilentlyContinue)} |
        ConvertTo-Json | Set-Content (Join-Path $DataDirectory 'probe-cleanup.json')
}
