# Принудительно используем TLS 1.2 для работы в старых версиях PowerShell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$installDir = Join-Path $env:LOCALAPPDATA "OpenAI\CodexProxyLauncher"
$launcherPath = Join-Path $installDir "Launch-ChatGPT-Proxy.ps1"
$windowlessLauncherPath = Join-Path $installDir "Launch-ChatGPT-Proxy.vbs"
$shortcutPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "ChatGPT Proxy.lnk"
$iconPath = $null

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

    # UWP-ярлык использует белые unplated-ресурсы из assets. Иконка из EXE
    # имеет другую (тёмную) расцветку, поэтому собираем ICO из тех же PNG.
    $assetDirectory = Join-Path $package.InstallLocation "assets"

    try {
        $iconImages = @(
            Get-ChildItem -LiteralPath $assetDirectory `
                -Filter "Square44x44Logo.targetsize-*_altform-unplated.png" `
                -File `
                -ErrorAction Stop |
                ForEach-Object {
                    $match = [regex]::Match(
                        $_.Name,
                        "targetsize-(\d+)_altform-unplated\.png$"
                    )

                    if ($match.Success) {
                        [PSCustomObject]@{
                            Size = [int]$match.Groups[1].Value
                            Data = [IO.File]::ReadAllBytes($_.FullName)
                        }
                    }
                } |
                Sort-Object Size
        )

        if ($iconImages.Count -gt 0) {
            # Суффикс меняет IconLocation и обходит старую запись кэша.
            $iconPath = Join-Path $installDir `
                "ChatGPT-$($package.Version)-unplated.ico"

            $stream = [IO.MemoryStream]::new()
            $writer = [IO.BinaryWriter]::new($stream)

            try {
                # ICONDIR
                $writer.Write([uint16]0)
                $writer.Write([uint16]1)
                $writer.Write([uint16]$iconImages.Count)

                $imageOffset = 6 + (16 * $iconImages.Count)

                # ICONDIRENTRY для каждого PNG-кадра.
                foreach ($image in $iconImages) {
                    $encodedSize = if ($image.Size -eq 256) {
                        0
                    } else {
                        $image.Size
                    }

                    $writer.Write([byte]$encodedSize)
                    $writer.Write([byte]$encodedSize)
                    $writer.Write([byte]0)
                    $writer.Write([byte]0)
                    $writer.Write([uint16]1)
                    $writer.Write([uint16]32)
                    $writer.Write([uint32]$image.Data.Length)
                    $writer.Write([uint32]$imageOffset)
                    $imageOffset += $image.Data.Length
                }

                foreach ($image in $iconImages) {
                    $writer.Write([byte[]]$image.Data)
                }

                $writer.Flush()
                [IO.File]::WriteAllBytes($iconPath, $stream.ToArray())
            }
            finally {
                $writer.Dispose()
                $stream.Dispose()
            }
        }
    }
    catch {
        $iconPath = $null
    }
}

# Создаём ярлык
$windowsPowerShell = Join-Path $env:SystemRoot `
    "System32\WindowsPowerShell\v1.0\powershell.exe"
$windowsScriptHost = Join-Path $env:SystemRoot "System32\wscript.exe"

# WScript запускает PowerShell сразу со скрытым окном. При прямом запуске
# powershell.exe консоль успевает появиться до обработки -WindowStyle Hidden.
$escapedPowerShell = $windowsPowerShell.Replace('"', '""')
$escapedLauncherPath = $launcherPath.Replace('"', '""')

@"
Set shell = CreateObject("WScript.Shell")
shell.Run """$escapedPowerShell"" -NoProfile -ExecutionPolicy Bypass -File ""$escapedLauncherPath""", 0, False
"@ | Set-Content -LiteralPath $windowlessLauncherPath -Encoding Unicode

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)

$shortcut.TargetPath = $windowsScriptHost
$shortcut.Arguments = "`"$windowlessLauncherPath`""
$shortcut.WorkingDirectory = $installDir
$shortcut.Description = "Запустить ChatGPT/Codex через v2rayN"
if ($iconPath -and (Test-Path -LiteralPath $iconPath)) {
    $shortcut.IconLocation = "$iconPath,0"
} elseif ($executable -and (Test-Path -LiteralPath $executable)) {
    $shortcut.IconLocation = "$executable,0"
}
$shortcut.Save()

Write-Host "Готово: $shortcutPath" -ForegroundColor Green
