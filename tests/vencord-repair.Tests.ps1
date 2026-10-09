# Offline fixtures: never run the installer, register tasks, or touch real Discord.
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path $PSScriptRoot) 'setup-vencord-launcher.ps1'
$fixture = Join-Path $env:TEMP ('vencord-test-' + [guid]::NewGuid().ToString('N'))
$previousLocal = $env:LOCALAPPDATA
$previousRoaming = $env:APPDATA
$previousProfile = $env:USERPROFILE
$launchProbe = @{ Allow = $false; Path = '' }
function Start-Process {
    param($FilePath)
    if (-not $launchProbe.Allow) { throw 'Tests must not launch an installer or Discord.' }
    $launchProbe.Path = $FilePath
}
function Get-Process { param($Name) return @() }
function Start-Sleep { param($Seconds, $Milliseconds) }
try {
    $env:LOCALAPPDATA = Join-Path $fixture 'local'
    $env:APPDATA = Join-Path $fixture 'roaming'
    $env:USERPROFILE = $fixture
    $resources = Join-Path $env:LOCALAPPDATA 'Discord\app-1.0.0001\resources'
    $dist = Join-Path $env:APPDATA 'Vencord\dist'
    New-Item -ItemType Directory -Path $resources, $dist -Force | Out-Null
    Set-Content (Join-Path $resources 'app.asar') 'Original Discord contains a Vencord mention'
    Set-Content (Join-Path $dist 'patcher.js') '// installed Vencord'
    if ((& $scriptPath -Mode Check).Patched) { throw 'Plain Discord was mistaken for Vencord.' }
    Set-Content (Join-Path $resources '_app.asar') 'Original Discord'
    if ((& $scriptPath -Mode Check).Patched) { throw 'Backup alone was mistaken for a valid patch.' }
    Set-Content (Join-Path $resources 'app.asar') 'require("Vencord/dist/patcher.js")'
    if (-not (& $scriptPath -Mode Check).Patched) { throw 'Valid patch was not detected.' }
    & $scriptPath -Mode Run
    if (Test-Path (Join-Path $env:USERPROFILE '.device-setup\VencordRepair\repair.log')) { throw 'Healthy install attempted a repair.' }
    $launchProbe.Allow = $true
    & $scriptPath -Mode Launch
    if ($launchProbe.Path -ne (Join-Path (Split-Path $resources) 'Discord.exe')) { throw "Launcher did not open the checked Discord version: $($launchProbe.Path)" }
    $launchLog = Get-Content (Join-Path $env:USERPROFILE '.device-setup\VencordRepair\repair.log') -Raw
    if ($launchLog -notmatch 'no background watcher remains') { throw 'Launch did not finish after Discord exited.' }
    $launchProbe.Allow = $false
    Remove-Item -LiteralPath (Join-Path $dist 'patcher.js')
    if ((& $scriptPath -Mode Check).Patched) { throw 'Missing Vencord build was not detected.' }
    Set-Content (Join-Path $dist 'patcher.js') '// installed Vencord'
    $newResources = Join-Path $env:LOCALAPPDATA 'Discord\app-1.0.0002\resources'
    New-Item -ItemType Directory -Path $newResources | Out-Null
    Set-Content (Join-Path $newResources 'app.asar') 'Fresh Discord update'
    $state = & $scriptPath -Mode Check
    if ($state.Version -ne 'app-1.0.0002' -or $state.Patched) { throw 'New unpatched update was not selected.' }
    foreach ($name in @('preload.js', 'renderer.js', 'renderer.css')) { Set-Content (Join-Path $dist $name) 'fixture' }
    $cache = Join-Path $fixture '.device-setup\VencordRepair\VencordInstallerCli.exe'
    Add-Type -OutputAssembly $cache -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
public static class FakeInstaller {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    public static int Main() {
        if (GetConsoleWindow() != IntPtr.Zero) return 2;
        string dir = Path.Combine(Environment.GetEnvironmentVariable("LOCALAPPDATA"), @"Discord\app-1.0.0002\resources");
        File.WriteAllText(Path.Combine(dir, "_app.asar"), "original fixture");
        File.WriteAllText(Path.Combine(dir, "app.asar"), "require('Vencord/dist/patcher.js')");
        Console.WriteLine("fixture repair without console");
        return 0;
    }
}
'@
    Set-Content "$cache.sha256" (Get-FileHash $cache).Hash
    & $scriptPath -Mode Run
    if ($LASTEXITCODE -ne 0 -or -not (& $scriptPath -Mode Check).Patched) { throw 'Console-free repair failed.' }
    Write-Host 'PASS: detection, missing build, update selection, healthy no-op, one-shot launch, and console-free repair.'
} finally {
    $env:LOCALAPPDATA = $previousLocal
    $env:APPDATA = $previousRoaming
    $env:USERPROFILE = $previousProfile
    $resolved = [IO.Path]::GetFullPath($fixture)
    $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
