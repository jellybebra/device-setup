$ErrorActionPreference = "Stop"

$ip = Read-Host "IP"
$port = Read-Host "Port"
$username = Read-Host "Username"
$alias = Read-Host "Alias"

$sshDir = Join-Path $HOME ".ssh"
$configFile = Join-Path $sshDir "config"

New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
if (-not (Test-Path $configFile)) {
    New-Item -ItemType File -Path $configFile -Force | Out-Null
}

function Remove-HostBlock {
    param(
        [string]$AliasName,
        [string]$FilePath
    )

    if (-not (Test-Path $FilePath)) { return }

    $lines = Get-Content -Path $FilePath -ErrorAction SilentlyContinue
    $result = New-Object System.Collections.Generic.List[string]
    $skip = $false

    foreach ($line in $lines) {
        if ($line -match "^\s*Host\s+$([regex]::Escape($AliasName))\s*$") {
            $skip = $true
            continue
        }

        if ($skip -and $line -match "^\s*Host\s+") {
            $skip = $false
        }

        if (-not $skip) {
            $result.Add($line)
        }
    }

    Set-Content -Path $FilePath -Value $result
}

function Add-HostBlock {
    param(
        [string]$AliasName,
        [string]$Ip,
        [string]$Port,
        [string]$Username,
        [string]$IdentityFile = ""
    )

    Add-Content -Path $configFile -Value ""
    Add-Content -Path $configFile -Value "Host $AliasName"
    Add-Content -Path $configFile -Value "  HostName $Ip"
    Add-Content -Path $configFile -Value "  Port $Port"
    Add-Content -Path $configFile -Value "  User $Username"
    if ($IdentityFile) {
        Add-Content -Path $configFile -Value "  IdentityFile $IdentityFile"
    }
}

Remove-HostBlock -AliasName $alias -FilePath $configFile
Add-HostBlock -AliasName $alias -Ip $ip -Port $port -Username $username

ssh -o StrictHostKeyChecking=accept-new $alias "mkdir -p ~/.ssh && chmod 700 ~/.ssh"

$keyFile = ""
if (Test-Path (Join-Path $sshDir "id_ed25519")) {
    $keyFile = Join-Path $sshDir "id_ed25519"
} elseif (Test-Path (Join-Path $sshDir "id_rsa")) {
    $keyFile = Join-Path $sshDir "id_rsa"
} else {
    $keyFile = Join-Path $sshDir "id_ed25519"
    ssh-keygen -t ed25519 -f $keyFile -N '""'
}

$pubFile = "$keyFile.pub"
$pubKey = (Get-Content -Path $pubFile -Raw).Trim()

try {
    Set-Clipboard -Value $pubKey
} catch {}

Start-Process notepad.exe $pubFile

ssh $alias "mkdir -p ~/.ssh && chmod 700 ~/.ssh && printf '%s\n' '$pubKey' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

$keyFileForConfig = $keyFile -replace "\\","/"
Remove-HostBlock -AliasName $alias -FilePath $configFile
Add-HostBlock -AliasName $alias -Ip $ip -Port $port -Username $username -IdentityFile $keyFileForConfig

Write-Host "Done."