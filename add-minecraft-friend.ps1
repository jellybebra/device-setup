[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$IPAddress,
    [string]$Group = 'Minecraft-Friends-25565-20260928'
)

# Invoke an advanced script block so SupportsShouldProcess also works when
# this file is loaded through Invoke-Expression (irm ... | iex).
. {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string[]]$IPAddress,
        [string]$Group = 'Minecraft-Friends-25565-20260928'
    )

    $ErrorActionPreference = 'Stop'

    function ConvertTo-IPv4Number([string]$Address) {
        if ($Address -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
            throw "Expected a single IPv4 address, got: $Address"
        }
        $parts = $Address.Split('.')
        [uint64]$number = 0
        foreach ($part in $parts) {
            if ([int]$part -gt 255) { throw "Invalid IPv4 address: $Address" }
            $number = $number * 256 + [int]$part
        }
        return $number
    }

    function ConvertFrom-IPv4Number([uint64]$Number) {
        return '{0}.{1}.{2}.{3}' -f (($Number -shr 24) -band 255), (($Number -shr 16) -band 255), (($Number -shr 8) -band 255), ($Number -band 255)
    }

    if (-not $IPAddress) {
        $IPAddress = (Read-Host 'Friend IPv4 address (multiple: separated by commas)') -split ','
    }
    $newNumbers = @($IPAddress | ForEach-Object {
        $number = ConvertTo-IPv4Number $_.Trim()
        if ($number -eq 0 -or $number -ge 3758096384 -or ($number -ge 2130706432 -and $number -le 2147483647)) {
            throw "Expected a unicast IPv4 address, not loopback: $_"
        }
        $number
    })

    # Only update the four rules installed for this Minecraft server. Never infer
    # a trusted address from logs or adopt a broad Java allow rule.
    $saved = @{}
    foreach ($protocol in @('TCP', 'UDP')) {
        foreach ($action in @('Allow', 'Block')) {
            $name = "$Group-$action-$protocol"
            $rule = Get-NetFirewallRule -PolicyStore PersistentStore -Name $name
            $port = $rule | Get-NetFirewallPortFilter
            $application = $rule | Get-NetFirewallApplicationFilter
            if ($rule.Group -ne $Group -or [string]$rule.Enabled -ne 'True' -or
                [string]$rule.Direction -ne 'Inbound' -or [string]$rule.Action -ne $action -or
                [string]$rule.Profile -ne 'Any' -or [string]$port.Protocol -ne $protocol -or
                [string]$port.LocalPort -ne '25565' -or [string]$port.RemotePort -ne 'Any' -or
                [string]$application.Program -ne 'Any') {
                throw "Unexpected firewall rule configuration: $name. No changes made."
            }
            $saved[$name] = @(($rule | Get-NetFirewallAddressFilter).RemoteAddress)
        }
    }
    $tcpAllowed = @($saved["$Group-Allow-TCP"] | ForEach-Object { ConvertTo-IPv4Number $_ } | Sort-Object -Unique)
    $udpAllowed = @($saved["$Group-Allow-UDP"] | ForEach-Object { ConvertTo-IPv4Number $_ } | Sort-Object -Unique)
    if (Compare-Object $tcpAllowed $udpAllowed) {
        throw 'TCP and UDP allow lists differ. Inspect the rules before updating.'
    }
    $numbers = @(@($tcpAllowed) + @($newNumbers) | Sort-Object -Unique)
    $allowed = @($numbers | ForEach-Object { ConvertFrom-IPv4Number $_ })

    # Windows block rules override allow rules, so block the complement of the
    # entire allow list. Two /1 prefixes cover IPv6; NetSecurity rejects ::/0.
    $blocked = @()
    [uint64]$start = 0
    foreach ($number in $numbers) {
        if ($start -eq ($number - 1)) {
            $blocked += ConvertFrom-IPv4Number $start
        } elseif ($start -lt $number) {
            $blocked += '{0}-{1}' -f (ConvertFrom-IPv4Number $start), (ConvertFrom-IPv4Number ($number - 1))
        }
        $start = $number + 1
    }
    if ($start -le 4294967295) {
        $blocked += '{0}-255.255.255.255' -f (ConvertFrom-IPv4Number $start)
    }
    $blocked += @('::/1', '8000::/1')

    if (-not $PSCmdlet.ShouldProcess('Minecraft port 25565 (TCP/UDP)', "Allow only: $($allowed -join ', ')")) { return }
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run PowerShell as administrator. No changes made.'
    }

    try {
        # Keep the old blocks until both allow lists have been updated.
        foreach ($protocol in @('TCP', 'UDP')) {
            Set-NetFirewallRule -PolicyStore PersistentStore -Name "$Group-Allow-$protocol" -RemoteAddress $allowed
        }
        foreach ($protocol in @('TCP', 'UDP')) {
            Set-NetFirewallRule -PolicyStore PersistentStore -Name "$Group-Block-$protocol" -RemoteAddress $blocked
        }
        foreach ($protocol in @('TCP', 'UDP')) {
            foreach ($action in @('Allow', 'Block')) {
                $rule = Get-NetFirewallRule -PolicyStore ActiveStore -Name "$Group-$action-$protocol"
                $actual = @(($rule | Get-NetFirewallAddressFilter).RemoteAddress)
                $expected = if ($action -eq 'Allow') { $allowed } else { $blocked }
                if (Compare-Object ($actual | Sort-Object) ($expected | Sort-Object)) {
                    throw "Active rule verification failed: $($rule.Name)"
                }
            }
        }
    } catch {
        $failure = $_
        # Restore the restrictive blocks first; attempt every restore even if one fails.
        foreach ($action in @('Block', 'Allow')) {
            foreach ($protocol in @('TCP', 'UDP')) {
                $name = "$Group-$action-$protocol"
                try { Set-NetFirewallRule -PolicyStore PersistentStore -Name $name -RemoteAddress $saved[$name] }
                catch { Write-Warning "Could not restore $name : $_" }
            }
        }
        throw $failure
    }
    Write-Host "Minecraft 25565 allowed IPv4 addresses: $($allowed -join ', ')"
} @PSBoundParameters
