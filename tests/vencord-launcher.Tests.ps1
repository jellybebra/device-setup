# Run in Windows PowerShell 5.1. Tests the real compiled launcher with an
# isolated worker; it never touches Discord or Task Scheduler.
$ErrorActionPreference = 'Stop'
$fixture = Join-Path $env:TEMP ('vencord-launcher-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    $launcher = Join-Path $fixture 'launcher.exe'
    Add-Type -Path (Join-Path (Split-Path $PSScriptRoot) 'vencord-launcher.cs') -OutputAssembly $launcher -OutputType WindowsApplication
    $bytes = [IO.File]::ReadAllBytes($launcher)
    $pe = [BitConverter]::ToInt32($bytes, 0x3c)
    if ([BitConverter]::ToUInt16($bytes, $pe + 24 + 68) -ne 2) { throw 'Launcher must use the GUI subsystem.' }
    @'
param([string]$Mode)
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class ConsoleProbe { [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); }'
@{ Mode = $Mode; ConsoleWindow = [ConsoleProbe]::GetConsoleWindow().ToInt64() } | ConvertTo-Json | Set-Content (Join-Path $PSScriptRoot 'probe.json')
exit 17
'@ | Set-Content -LiteralPath (Join-Path $fixture 'setup-vencord-launcher.ps1') -Encoding UTF8
    $process = Start-Process -FilePath $launcher -WindowStyle Hidden -PassThru -Wait
    if ($process.ExitCode -ne 17) { throw 'Launcher lost the child exit code.' }
    $probe = Get-Content (Join-Path $fixture 'probe.json') -Raw | ConvertFrom-Json
    if ($probe.Mode -ne 'Launch' -or $probe.ConsoleWindow -ne 0) { throw 'Worker received incorrect arguments or acquired a console.' }
    Write-Host 'PASS: GUI launcher, console-free PowerShell child, arguments, and exit code propagation.'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
