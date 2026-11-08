$ErrorActionPreference = 'Stop'

# GitHub requires TLS 1.2 on older versions of Windows PowerShell.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$installerPath = Join-Path $env:TEMP 'VencordInstallerCli.exe'
$installerUrl = 'https://github.com/Vencord/Installer/releases/latest/download/VencordInstallerCli.exe'

Write-Host 'Downloading Vencord installer...' -ForegroundColor Cyan

try {
    Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath

    Write-Host 'Installing Vencord...' -ForegroundColor Cyan
    $installer = Start-Process `
        -FilePath $installerPath `
        -ArgumentList '-install', '-branch', 'auto' `
        -NoNewWindow `
        -PassThru `
        -Wait

    if ($installer.ExitCode -ne 0) {
        throw "Vencord installer exited with code $($installer.ExitCode)."
    }
} finally {
    Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
}

Write-Host 'Vencord installed successfully.' -ForegroundColor Green

foreach ($discordName in @('Discord', 'DiscordPTB', 'DiscordCanary')) {
    $updaterPath = Join-Path $env:LOCALAPPDATA "$discordName\Update.exe"

    if (Test-Path -LiteralPath $updaterPath) {
        $discordExe = if ($discordName -eq 'Discord') { 'Discord.exe' } else { "$discordName.exe" }
        Start-Process -FilePath $updaterPath -ArgumentList "--processStart $discordExe"
        break
    }
}
