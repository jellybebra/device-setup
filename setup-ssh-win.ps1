$ip = Read-Host "ip"
$port = Read-Host "port"
$username = Read-Host "username"
$alias = Read-Host "alias"

$sshDir = Join-Path $env:USERPROFILE ".ssh"
$keyBase = Join-Path $sshDir "id_ed25519"
$pubKeyFile = "$keyBase.pub"
$configFile = Join-Path $sshDir "config"

New-Item -ItemType Directory -Force -Path $sshDir | Out-Null

if (-not (Test-Path $keyBase) -or -not (Test-Path $pubKeyFile)) {
    & ssh-keygen -t ed25519 -f $keyBase -N '""'
}

$pubKeyContent = (Get-Content $pubKeyFile -Raw).Trim()

$remoteCmd = @"
mkdir -p ~/.ssh &&
chmod 700 ~/.ssh &&
touch ~/.ssh/authorized_keys &&
chmod 600 ~/.ssh/authorized_keys &&
grep -qxF '$pubKeyContent' ~/.ssh/authorized_keys || echo '$pubKeyContent' >> ~/.ssh/authorized_keys
"@

& ssh -p $port "$username@$ip" $remoteCmd

$newBlock = @"

Host $alias
  HostName $ip
  Port $port
  User $username
  IdentityFile $keyBase
"@

if (Test-Path $configFile) {
    $lines = Get-Content $configFile
    $result = New-Object System.Collections.Generic.List[string]
    $skip = $false

    foreach ($line in $lines) {
        if ($line -match '^\s*Host\s+(.+)\s*$') {
            $hostName = $matches[1].Trim()
            if ($skip) { $skip = $false }
            if ($hostName -eq $alias) {
                $skip = $true
                continue
            }
        }
        if (-not $skip) {
            $result.Add($line)
        }
    }

    $content = (($result -join "`r`n").TrimEnd() + "`r`n" + $newBlock.Trim() + "`r`n")
    Set-Content -Path $configFile -Value $content -NoNewline
} else {
    Set-Content -Path $configFile -Value ($newBlock.Trim() + "`r`n") -NoNewline
}