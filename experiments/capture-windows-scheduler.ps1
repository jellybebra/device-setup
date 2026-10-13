param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateRange(5, 60)][int]$Seconds = 30
)
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this diagnostic from an elevated PowerShell.'
}
$root = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $root) { throw 'Use a new output directory for each recording.' }
New-Item -ItemType Directory -Path $root | Out-Null
$profile = Join-Path $PSScriptRoot 'windows-scheduler.wprp'
$started = $false
$failure = $null
function Invoke-Recorder([string[]]$RecorderArguments, [string]$LogName) {
    # Redirect native stderr directly: Windows PowerShell can treat a blank
    # diagnostic line as a terminating NativeCommandError under Stop.
    $process = Start-Process wpr.exe -ArgumentList $RecorderArguments -Wait -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $root "$LogName.log") `
        -RedirectStandardError (Join-Path $root "$LogName.err")
    return $process.ExitCode
}
try {
    $statusExit = Invoke-Recorder @('-status') 'initial-status'
    $state = Get-Content (Join-Path $root 'initial-status.log') -Raw
    if ($statusExit -ne 0 -or $state -notmatch 'WPR is not recording') {
        throw 'Recorder is not confirmed idle; refusing to alter another recording.'
    }
    $startExit = Invoke-Recorder @('-start', ('"{0}!Scheduler"' -f $profile), '-filemode') 'start'
    if ($startExit -ne 0) { throw "WPR start failed ($startExit); inspect start.log and start.err." }
    $started = $true
    Start-Sleep -Seconds $Seconds
} catch {
    $failure = $_.Exception.Message
} finally {
    if ($started) {
        $stopExit = Invoke-Recorder @('-stop', ('"{0}"' -f (Join-Path $root 'scheduler.etl'))) 'stop'
        if ($stopExit -ne 0) { $failure = "WPR stop failed ($stopExit); inspect stop logs and recorder status." }
    }
    $null = Invoke-Recorder @('-status') 'final-status'
    @{ started = $started; error = $failure; at = (Get-Date -Format o) } |
        ConvertTo-Json | Set-Content (Join-Path $root 'status.json') -Encoding UTF8
}
if ($failure) { throw $failure }
