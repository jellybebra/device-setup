$sshDir = Join-Path $env:USERPROFILE ".ssh"
$keyBase = Join-Path $sshDir "id_ed25519"
$pubKeyFile = "$keyBase.pub"
$configFile = Join-Path $sshDir "config"

# Ensure SSH directory exists
if (-not (Test-Path $sshDir)) {
    New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
}

function Get-SSHConfig {
    if (-not (Test-Path $configFile)) {
        return @()
    }

    $hosts = [System.Collections.Generic.List[PSObject]]::new()
    $lines = Get-Content $configFile

    $currentHost = $null

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith("#") -or $trimmed.Length -eq 0) {
            continue
        }

        # Split key-value on first whitespace
        $parts = $trimmed -split '\s+', 2
        if ($parts.Length -lt 2) { continue }

        $key = $parts[0].ToLower()
        $val = $parts[1].Trim()

        if ($key -eq "host") {
            if ($currentHost -and $currentHost.Alias -ne "*") {
                $hosts.Add($currentHost)
            }
            $currentHost = [PSCustomObject]@{
                Alias        = $val
                HostName     = ""
                Port         = "22"
                User         = ""
                IdentityFile = ""
            }
        } elseif ($currentHost) {
            if ($key -eq "hostname") {
                $currentHost.HostName = $val
            } elseif ($key -eq "port") {
                $currentHost.Port = $val
            } elseif ($key -eq "user") {
                $currentHost.User = $val
            } elseif ($key -eq "identityfile") {
                $currentHost.IdentityFile = $val
            }
        }
    }

    if ($currentHost -and $currentHost.Alias -ne "*") {
        $hosts.Add($currentHost)
    }

    return $hosts
}

function Show-Menu {
    param (
        [string]$Title,
        [string[]]$Options
    )
    $current = 0
    $numOptions = $Options.Length

    while ($true) {
        Clear-Host
        Write-Host $Title -ForegroundColor Cyan
        for ($i = 0; $i -lt $numOptions; $i++) {
            if ($i -eq $current) {
                Write-Host " > $($Options[$i])" -ForegroundColor Green
            } else {
                Write-Host "   $($Options[$i])"
            }
        }

        $keyInfo = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        $key = $keyInfo.VirtualKeyCode

        if ($key -eq 38) { # Up arrow
            $current--
            if ($current -lt 0) { $current = $numOptions - 1 }
            if ($Options[$current] -eq "---------------------------") {
                $current--
                if ($current -lt 0) { $current = $numOptions - 1 }
            }
        } elseif ($key -eq 40) { # Down arrow
            $current++
            if ($current -ge $numOptions) { $current = 0 }
            if ($Options[$current] -eq "---------------------------") {
                $current++
                if ($current -ge $numOptions) { $current = 0 }
            }
        } elseif ($key -eq 13) { # Enter
            break
        }
    }
    return $current
}

function Remove-HostFromConfig {
    param ([string]$AliasToRemove)
    if (-not (Test-Path $configFile)) { return }

    $lines = Get-Content $configFile
    $result = New-Object System.Collections.Generic.List[string]
    $skip = $false

    foreach ($line in $lines) {
        if ($line -match '^\s*Host\s+(.+)\s*$') {
            $hostName = $Matches[1].Trim()
            if ($skip) { $skip = $false }
            if ($hostName -eq $AliasToRemove) {
                $skip = $true
                continue
            }
        }
        if (-not $skip) {
            $result.Add($line)
        }
    }

    $content = ($result -join "`r`n").TrimEnd()
    if ($content.Length -gt 0) {
        $content = $content + "`r`n"
    }
    Set-Content -Path $configFile -Value $content -NoNewline
}

function Add-NewServer {
    Clear-Host
    Write-Host "=== Add a New Server ===" -ForegroundColor Cyan

    $alias = Read-Host "Alias (e.g., work-server)"
    if ([string]::IsNullOrWhiteSpace($alias)) {
        Write-Host "[!] Alias cannot be empty." -ForegroundColor Red
        Start-Sleep -Seconds 2
        return
    }

    # Check for duplicate alias
    $existingHosts = Get-SSHConfig
    foreach ($h in $existingHosts) {
        if ($h.Alias -eq $alias) {
            Write-Host "[!] A server with alias '$alias' already exists." -ForegroundColor Red
            Start-Sleep -Seconds 2
            return
        }
    }

    $ip = Read-Host "IP address"
    if ([string]::IsNullOrWhiteSpace($ip)) {
        Write-Host "[!] IP address cannot be empty." -ForegroundColor Red
        Start-Sleep -Seconds 2
        return
    }

    $port = Read-Host "Port [22]"
    if ([string]::IsNullOrWhiteSpace($port)) { $port = "22" }

    $username = Read-Host "Username [root]"
    if ([string]::IsNullOrWhiteSpace($username)) { $username = "root" }

    Write-Host "`n[i] Setting up SSH keys..." -ForegroundColor Blue
    if (-not (Test-Path $keyBase) -or -not (Test-Path $pubKeyFile)) {
        Write-Host "[i] Generating new SSH key pair (Ed25519)..." -ForegroundColor Blue
        & ssh-keygen -t ed25519 -f $keyBase -N '""'
    }

    $pubKeyContent = (Get-Content $pubKeyFile -Raw).Trim()

    Write-Host "[i] Copying public key to remote host (you may be prompted for password)..." -ForegroundColor Blue
    $remoteCmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -qxF '$pubKeyContent' ~/.ssh/authorized_keys || echo '$pubKeyContent' >> ~/.ssh/authorized_keys"

    $process = Start-Process ssh -ArgumentList "-p $port -o ConnectTimeout=10 $username@$ip `"$remoteCmd`"" -Wait -PassThru
    if ($process.ExitCode -eq 0) {
        Write-Host "[+] SSH key successfully copied to remote host!" -ForegroundColor Green
    } else {
        Write-Host "[!] Failed to copy SSH key to remote host." -ForegroundColor Red
        $saveAnyway = Read-Host "Do you still want to save this server configuration? (y/N)"
        if ($saveAnyway -notmatch '^[Yy]$') {
            Write-Host "[i] Aborted." -ForegroundColor Yellow
            Start-Sleep -Seconds 2
            return
        }
    }

    # Remove existing if any, and write
    Remove-HostFromConfig $alias

    $newBlock = @"
Host $alias
  HostName $ip
  Port $port
  User $username
  IdentityFile $keyBase
"@

    if (Test-Path $configFile) {
        $content = Get-Content $configFile -Raw
        $newContent = $content.TrimEnd() + "`r`n`r`n" + $newBlock + "`r`n"
        Set-Content -Path $configFile -Value $newContent -NoNewline
    } else {
        Set-Content -Path $configFile -Value ($newBlock + "`r`n") -NoNewline
    }

    Write-Host "[+] Server '$alias' successfully configured and saved!" -ForegroundColor Green
    Start-Sleep -Seconds 2
}

function Edit-Server {
    param ($HostObj)
    
    $originalAlias = $HostObj.Alias
    $currentAlias = $HostObj.Alias
    $currentIp = $HostObj.HostName
    $currentPort = $HostObj.Port
    $currentUser = $HostObj.User
    $identityFile = $HostObj.IdentityFile
    if ([string]::IsNullOrWhiteSpace($identityFile)) { $identityFile = $keyBase }

    while ($true) {
        $editOptions = @(
            "Alias: $currentAlias",
            "IP Address: $currentIp",
            "Port: $currentPort",
            "Username: $currentUser",
            "[ Save & Back ]",
            "[ Cancel ]"
        )
        
        $editChoice = Show-Menu "=== Edit Server: $originalAlias ===" $editOptions
        
        if ($editChoice -eq 0) {
            # Edit Alias
            $inputVal = Read-Host "Enter new Alias [$currentAlias]"
            if (-not [string]::IsNullOrWhiteSpace($inputVal)) {
                if ($inputVal -ne $originalAlias) {
                    $existingHosts = Get-SSHConfig
                    $exists = $false
                    foreach ($h in $existingHosts) {
                        if ($h.Alias -eq $inputVal) {
                            $exists = $true
                            break
                        }
                    }
                    if ($exists) {
                        Write-Host "[!] A server with alias '$inputVal' already exists." -ForegroundColor Red
                        Start-Sleep -Seconds 2
                        continue
                    }
                }
                $currentAlias = $inputVal
            }
        } elseif ($editChoice -eq 1) {
            # Edit IP
            $inputVal = Read-Host "Enter new IP address [$currentIp]"
            if (-not [string]::IsNullOrWhiteSpace($inputVal)) {
                $currentIp = $inputVal
            }
        } elseif ($editChoice -eq 2) {
            # Edit Port
            $inputVal = Read-Host "Enter new Port [$currentPort]"
            if (-not [string]::IsNullOrWhiteSpace($inputVal)) {
                $currentPort = $inputVal
            }
        } elseif ($editChoice -eq 3) {
            # Edit Username
            $inputVal = Read-Host "Enter new Username [$currentUser]"
            if (-not [string]::IsNullOrWhiteSpace($inputVal)) {
                $currentUser = $inputVal
            }
        } elseif ($editChoice -eq 4) {
            # Save & Back
            Remove-HostFromConfig $originalAlias

            $newBlock = @"
Host $currentAlias
  HostName $currentIp
  Port $currentPort
  User $currentUser
  IdentityFile $identityFile
"@

            if (Test-Path $configFile) {
                $content = Get-Content $configFile -Raw
                $newContent = $content.TrimEnd() + "`r`n`r`n" + $newBlock + "`r`n"
                Set-Content -Path $configFile -Value $newContent -NoNewline
            } else {
                Set-Content -Path $configFile -Value ($newBlock + "`r`n") -NoNewline
            }

            Write-Host "[+] Server '$currentAlias' successfully updated!" -ForegroundColor Green
            Start-Sleep -Seconds 1.5
            break
        } elseif ($editChoice -eq 5) {
            # Cancel
            break
        }
    }
}

function Delete-Server {
    param ($HostObj)
    Clear-Host
    Write-Host "=== Delete Server: $($HostObj.Alias) ===" -ForegroundColor Red
    $confirm = Read-Host "Are you sure you want to delete '$($HostObj.Alias)' from config? (y/N)"
    if ($confirm -notmatch '^[Yy]$') {
        Write-Host "[i] Deletion canceled." -ForegroundColor Yellow
        Start-Sleep -Seconds 1.5
        return
    }

    Remove-HostFromConfig $HostObj.Alias
    Write-Host "[+] Server '$($HostObj.Alias)' successfully removed." -ForegroundColor Green
    Start-Sleep -Seconds 1.5
}

# Main Loop
while ($true) {
    $hosts = Get-SSHConfig

    $menuOptions = New-Object System.Collections.Generic.List[string]
    foreach ($h in $hosts) {
        $info = ""
        if (-not [string]::IsNullOrWhiteSpace($h.User)) {
            $info += "$($h.User)@"
        }
        $info += $h.HostName
        if (-not [string]::IsNullOrWhiteSpace($h.Port) -and $h.Port -ne "22") {
            $info += ":$($h.Port)"
        }
        $menuOptions.Add("$($h.Alias) ($info)")
    }

    $menuOptions.Add("---------------------------")
    $menuOptions.Add("[+] Add a new server")
    $menuOptions.Add("[x] Exit")

    $choice = Show-Menu "=== SSH Server Manager ===" ($menuOptions.ToArray())

    $numServers = $hosts.Count

    if ($choice -lt $numServers) {
        $selectedHost = $hosts[$choice]

        while ($true) {
            $actionChoice = Show-Menu "=== Server: $($selectedHost.Alias) ($($selectedHost.User)@$($selectedHost.HostName):$($selectedHost.Port)) ===" @("Connect", "Edit", "Delete", "[ Back ]")

            if ($actionChoice -eq 0) {
                # Connect
                Clear-Host
                Write-Host "Connecting to $($selectedHost.Alias)..." -ForegroundColor Green
                Write-Host "----------------------------------------"
                & ssh $($selectedHost.Alias)
                Write-Host "----------------------------------------"
                Read-Host "Connection closed. Press Enter to return to menu..."
                break
            } elseif ($actionChoice -eq 1) {
                # Edit
                Edit-Server $selectedHost
                break
            } elseif ($actionChoice -eq 2) {
                # Delete
                Delete-Server $selectedHost
                break
            } elseif ($actionChoice -eq 3) {
                # Back
                break
            }
        }
    } elseif ($choice -eq ($numServers + 1)) {
        # Add new server
        Add-NewServer
    } elseif ($choice -eq ($numServers + 2)) {
        # Exit
        Clear-Host
        Write-Host "Goodbye!"
        exit 0
    }
}