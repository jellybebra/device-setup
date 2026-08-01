# Принудительно используем TLS 1.2 для работы в старых версиях PowerShell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$installDir = Join-Path $env:LOCALAPPDATA "OpenAI\CodexProxyLauncher"
$launcherPath = Join-Path $installDir "Launch-ChatGPT-Proxy.ps1"
$shortcutPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "ChatGPT Proxy.lnk"
$iconPath = Join-Path $installDir "ChatGPT.ico"

New-Item -ItemType Directory -Force -Path $installDir | Out-Null

@'
$ErrorActionPreference = "Stop"

$proxyHost = "127.0.0.1"
$proxyPort = 10808
$proxy = "http://${proxyHost}:${proxyPort}"

function Show-Error([string]$message) {
    $shell = New-Object -ComObject WScript.Shell
    $shell.Popup($message, 0, "ChatGPT Proxy", 16) | Out-Null
}

# Проверка локального proxy
$client = [Net.Sockets.TcpClient]::new()

try {
    $connection = $client.ConnectAsync($proxyHost, $proxyPort)

    if (-not $connection.Wait(1500) -or -not $client.Connected) {
        Show-Error "Proxy ${proxyHost}:${proxyPort} недоступен. Запустите v2rayN."
        exit 2
    }
}
catch {
    Show-Error "Proxy ${proxyHost}:${proxyPort} недоступен. Запустите v2rayN."
    exit 2
}
finally {
    $client.Dispose()
}

# Поиск актуального пакета
$package = Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue |
    Where-Object { $_.InstallLocation } |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $package) {
    Show-Error "Пакет OpenAI.Codex не найден."
    exit 3
}

$manifestPath = Join-Path $package.InstallLocation "AppxManifest.xml"
[xml]$manifest = Get-Content -LiteralPath $manifestPath

$application = @($manifest.Package.Applications.Application) |
    Where-Object { $_.Executable } |
    Select-Object -First 1

$relativeExe = $application.Executable -replace "/", "\"
$executable = Join-Path $package.InstallLocation $relativeExe

if (-not (Test-Path $executable)) {
    Show-Error "Исполняемый файл приложения не найден."
    exit 4
}

# Находим только процессы установленного desktop-приложения
$desktopProcesses = @(
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -in @("ChatGPT.exe", "Codex.exe") -and
            $_.ExecutablePath -and
            $_.ExecutablePath.StartsWith(
                $package.InstallLocation,
                [StringComparison]::OrdinalIgnoreCase
            )
        }
)

if ($desktopProcesses.Count -gt 0) {
    $shell = New-Object -ComObject WScript.Shell
    $answer = $shell.Popup(
        "ChatGPT/Codex уже запущен. Перезапустить его через proxy?",
        0,
        "ChatGPT Proxy",
        4 + 32
    )

    if ($answer -ne 6) {
        exit
    }

    foreach ($process in $desktopProcesses) {
        Start-Process taskkill.exe `
            -ArgumentList "/PID $($process.ProcessId) /T /F" `
            -WindowStyle Hidden `
            -Wait
    }

    Start-Sleep -Milliseconds 800
}

# Запуск с отдельным окружением процесса
$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $executable
$startInfo.UseShellExecute = $false
$startInfo.Arguments = @(
    "--proxy-server=$proxy"
    '--proxy-bypass-list=<-loopback>;localhost;127.0.0.1;::1'
    "--disable-quic"
) -join " "

foreach ($name in @(
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "http_proxy",
    "https_proxy"
)) {
    $startInfo.EnvironmentVariables[$name] = $proxy
}

foreach ($name in @("NO_PROXY", "no_proxy")) {
    $startInfo.EnvironmentVariables[$name] = "localhost,127.0.0.1,::1"
}

[Diagnostics.Process]::Start($startInfo) | Out-Null
'@ | Set-Content -LiteralPath $launcherPath -Encoding UTF8

# Получаем текущую иконку приложения
$package = Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue |
    Where-Object { $_.InstallLocation } |
    Sort-Object Version -Descending |
    Select-Object -First 1

$executable = $null
if ($package) {
    $manifestPath = Join-Path $package.InstallLocation "AppxManifest.xml"
    if (Test-Path -LiteralPath $manifestPath) {
        [xml]$manifest = Get-Content -LiteralPath $manifestPath
        $relativeExe = (
            @($manifest.Package.Applications.Application) |
            Where-Object { $_.Executable } |
            Select-Object -First 1
        ).Executable -replace "/", "\"
        $executable = Join-Path $package.InstallLocation $relativeExe
    }
}

if ($executable -and (Test-Path -LiteralPath $executable)) {
    try {
        Add-Type -AssemblyName System.Drawing
        $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($executable)
        $stream = [IO.File]::Create($iconPath)

        try {
            $icon.Save($stream)
        }
        finally {
            $stream.Dispose()
            $icon.Dispose()
        }
    }
    catch {
        $iconPath = $executable
    }
}

# Создаём ярлык
$windowsPowerShell = Join-Path $env:SystemRoot `
    "System32\WindowsPowerShell\v1.0\powershell.exe"

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)

$shortcut.TargetPath = $windowsPowerShell
$shortcut.Arguments = (
    '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden ' +
    "-File `"$launcherPath`""
)
$shortcut.WorkingDirectory = $installDir
$shortcut.Description = "Запустить ChatGPT/Codex через v2rayN"
if (Test-Path -LiteralPath $iconPath) {
    $shortcut.IconLocation = "$iconPath,0"
} elseif ($executable -and (Test-Path -LiteralPath $executable)) {
    $shortcut.IconLocation = "$executable,0"
}
$shortcut.Save()

Write-Host "Готово: $shortcutPath" -ForegroundColor Green
