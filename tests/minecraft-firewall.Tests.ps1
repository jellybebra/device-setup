# Run with Windows PowerShell 5.1 or PowerShell 7 on Windows. No elevation or
# firewall mutations: mocked reads and -WhatIf exercise the real script.
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path $PSScriptRoot) 'add-minecraft-friend.ps1'
$script:existing = @('192.0.2.10', '198.51.100.20', '203.0.113.30')
function Get-NetFirewallRule {
    param($PolicyStore, $Name)
    $pieces = $Name.Split('-')
    [pscustomobject]@{Name=$Name; Group='Minecraft-Friends-25565-20260928'; Enabled='True'; Direction='Inbound'; Action=$pieces[-2]; Profile='Any'; Protocol=$pieces[-1]}
}
function Get-NetFirewallPortFilter {
    param([Parameter(ValueFromPipeline)]$Rule)
    process { [pscustomobject]@{Protocol=$Rule.Protocol; LocalPort='25565'; RemotePort='Any'} }
}
function Get-NetFirewallApplicationFilter {
    param([Parameter(ValueFromPipeline)]$Rule)
    process { [pscustomobject]@{Program='Any'} }
}
function Get-NetFirewallAddressFilter {
    param([Parameter(ValueFromPipeline)]$Rule)
    process { [pscustomobject]@{RemoteAddress=$script:existing} }
}
function Set-NetFirewallRule { throw 'Tests must never modify firewall rules.' }

. $scriptPath -IPAddress '203.0.113.7','203.0.113.8','203.0.113.10','192.0.2.10' -WhatIf
if ($allowed.Count -ne 6) { throw 'Existing addresses or deduplication failed.' }
if (Compare-Object ($blocked | Select-Object -Last 2) @('::/1','8000::/1')) { throw 'IPv6 coverage failed.' }
# Verify the entire IPv4 space, not only selected example addresses: every
# gap between allowed singletons must be represented once, without overlap.
$intervals = @($blocked | Where-Object { $_ -notmatch ':' } | ForEach-Object {
    $ends = $_.Split('-')
    [pscustomobject]@{First=(ConvertTo-IPv4Number $ends[0]); Last=(ConvertTo-IPv4Number $ends[-1])}
})
$intervals += @($allowed | ForEach-Object {
    $n = ConvertTo-IPv4Number $_
    [pscustomobject]@{First=$n;Last=$n}
})
[uint64]$next = 0
foreach ($interval in ($intervals | Sort-Object First)) {
    if ($interval.First -ne $next -or $interval.Last -lt $interval.First) { throw 'IPv4 gap or overlap.' }
    $next = $interval.Last + 1
}
if ($next -ne 4294967296) { throw 'Incomplete IPv4 coverage.' }

$before = $allowed -join ','
$script:existing = $allowed
. $scriptPath -IPAddress '203.0.113.7' -WhatIf
if (($allowed -join ',') -ne $before) { throw 'Repeated addition changed the list.' }

foreach ($bad in @('Any','1.2.3.4/24','::1','1.2.3.999','127.0.0.1','0.0.0.0','224.0.0.1','255.255.255.255','')) {
    $rejected = $false
    try { & $scriptPath -IPAddress @($bad,'203.0.113.7') -WhatIf }
    catch { $rejected = $true }
    if (-not $rejected) { throw "Accepted invalid address: $bad" }
}
$WhatIfPreference = $true
function Read-Host { '203.0.113.7' }
Get-Content -LiteralPath $scriptPath -Raw | Invoke-Expression
Write-Host 'PASS: preservation, deduplication, adjacent addresses, complete IPv4/IPv6 coverage and invalid input.'
