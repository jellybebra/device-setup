# Принудительно используем TLS 1.2 для работы с API GitHub (нужно для старых версий Windows)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "=== Установка Antigravity Proxy (Авто-версия) ===" -ForegroundColor Cyan

# --- Определение архитектуры ---
$is64Bit = ($env:PROCESSOR_ARCHITECTURE -eq 'AMD64') -or ($env:PROCESSOR_ARCHITEW6432 -eq 'AMD64')
$arch = if ($is64Bit) { "x64" } else { "x86" }
Write-Host "Определена архитектура системы: $arch" -ForegroundColor Yellow

# --- Поиск последнего релиза на GitHub ---
Write-Host "Поиск последней версии на GitHub..."
$apiUrl = "https://api.github.com/repos/yuaotian/antigravity-proxy/releases/latest"

try {
    $release = Invoke-RestMethod -Uri $apiUrl
    $version = $release.tag_name
    Write-Host "Найдена последняя версия: $version" -ForegroundColor Green
} catch {
    Write-Host "Ошибка при получении данных с GitHub API. Проверьте интернет или VPN." -ForegroundColor Red
    exit
}

# Ищем ссылку на архив, в названии которого есть наша архитектура (win-x64.zip или win-x86.zip)
$asset = $release.assets | Where-Object { $_.name -match "win-$arch\.zip$" }
if (-not $asset) {
    Write-Host "Ошибка: Архив для архитектуры $arch не найден в релизе $version!" -ForegroundColor Red
    exit
}

$downloadUrl = $asset.browser_download_url
Write-Host "Ссылка для скачивания: $downloadUrl" -ForegroundColor DarkGray

# --- Настройки путей ---
$installFolder = "$env:LOCALAPPDATA\Programs\Antigravity"
$tempZip = "$env:TEMP\antigravity-proxy.zip"
$tempExtract = "$env:TEMP\antigravity-proxy-extracted"

# 1. Закрытие Antigravity
Write-Host "[1/6] Закрытие процесса Antigravity (если запущен)..."
Get-Process -Name "Antigravity" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

if (-Not (Test-Path $installFolder)) {
    Write-Host "Папка установки $installFolder не найдена! Создаем ее..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $installFolder | Out-Null
}

# 2. Скачивание архива
Write-Host "[2/6] Скачивание архива..."
Invoke-WebRequest -Uri $downloadUrl -OutFile $tempZip

# 3. Распаковка
Write-Host "[3/6] Распаковка архива..."
if (Test-Path $tempExtract) { Remove-Item -Path $tempExtract -Recurse -Force }
Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force

# 4. Поиск и копирование файла version.dll
Write-Host "[4/6] Установка файла version.dll..."
$dllFile = Get-ChildItem -Path $tempExtract -Filter "version.dll" -Recurse | Select-Object -First 1

if ($dllFile) {
    Copy-Item -Path $dllFile.FullName -Destination "$installFolder\version.dll" -Force
} else {
    Write-Host "Ошибка: Файл version.dll не найден в скачанном архиве!" -ForegroundColor Red
    exit
}

# 5. Создание правильного config.json
Write-Host "[5/6] Создание config.json (SOCKS5 127.0.0.1:10808)..."
$configData = @"
{
  "proxy": {
    "host": "127.0.0.1",
    "port": 10808,
    "type": "socks5"
  }
}
"@
Set-Content -Path "$installFolder\config.json" -Value $configData -Encoding UTF8

# 6. Очистка мусора
Write-Host "[6/6] Очистка временных файлов..."
Remove-Item -Path $tempZip -Force -ErrorAction SilentlyContinue
Remove-Item -Path $tempExtract -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Установка успешно завершена (Установлена $version для $arch)!" -ForegroundColor Green
Write-Host "Теперь вы можете запустить Antigravity обычным способом." -ForegroundColor Green
