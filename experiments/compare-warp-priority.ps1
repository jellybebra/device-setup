param(
    [Parameter(Mandatory=$true)][string]$DataDirectory,
    [Parameter(Mandatory=$true)][string]$TrialState,
    [ValidateRange(10,60)][int]$SecondsPerPhase = 45,
    [ValidateSet('AboveNormal','High')][string]$Priority = 'AboveNormal',
    [string]$ResultsDirectory
)
$ErrorActionPreference = 'Stop'
[System.Diagnostics.Process]::GetCurrentProcess().PriorityClass='AboveNormal'
if(-not $ResultsDirectory){$ResultsDirectory=$DataDirectory}
if(-not (Test-Path -LiteralPath $ResultsDirectory)){[void](New-Item -ItemType Directory -Path $ResultsDirectory)}
$python=(Get-Command python.exe).Source
$compare=Join-Path $PSScriptRoot 'compare-native-wg.py'
$states=@(Get-Content -Raw -LiteralPath $TrialState | ConvertFrom-Json)
$states+=Get-Content -Raw -LiteralPath (Join-Path $DataDirectory 'relay-process.json') | ConvertFrom-Json
$owned=@()
foreach($entry in $states){
    $p=Get-Process -Id $entry.PID -ErrorAction Stop
    if($p.Path -ne $entry.Path -or [Math]::Abs(($p.StartTime.ToUniversalTime()-([datetime]$entry.Started).ToUniversalTime()).TotalMilliseconds) -ge 1){throw 'Runtime process identity mismatch'}
    $owned+=@{Process=$p; Original=$p.PriorityClass}
}
$phases=@()
$elevatedLabel=if($Priority -eq 'High'){'high'}else{'above-normal'}
try {
    foreach($phase in @('before',$elevatedLabel,'after')){
        foreach($entry in $owned){
            if($entry.Process.HasExited){throw 'A transport process exited'}
            $entry.Process.PriorityClass=if($phase -eq $elevatedLabel){$Priority}else{$entry.Original}
        }
        $phases+=@{phase=$phase; at=(Get-Date).ToString('o'); priorities=@($owned|ForEach-Object{@{pid=$_.Process.Id; priority=[string]$_.Process.PriorityClass}})}
        $phases|ConvertTo-Json -Depth 5|Set-Content (Join-Path $ResultsDirectory 'transport-priority-phases.json')
        & $python $compare --seconds $SecondsPerPhase --priority above-normal --output (Join-Path $ResultsDirectory "priority-$phase.json")
        if($LASTEXITCODE){throw "Measurement phase failed: $phase"}
    }
} finally {
    foreach($entry in $owned){if(-not $entry.Process.HasExited){$entry.Process.PriorityClass=$entry.Original}}
    @($owned|ForEach-Object{@{pid=$_.Process.Id; restored=($_.Process.HasExited -or $_.Process.PriorityClass -eq $_.Original); original=[string]$_.Original}})|ConvertTo-Json|Set-Content (Join-Path $ResultsDirectory 'transport-priority-restored.json')
}
