# Quick diagnostic: is the app collecting?
# A different database can be passed: .\Status.ps1 -Database C:\path\to\mt.db
# Not -Db: variable names are case-insensitive and that would shadow $Db.
param([string]$Database = '')
. "$PSScriptRoot\MtLib.ps1"
# -match on the -File form, and never the caller: a plain -like matches any
# process whose command line merely mentions the script, this one included.
$proc = @(Get-CimInstance Win32_Process -Filter 'Name="powershell.exe"' |
          Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match '-[Ff]ile\s+\S*MergeTactics\.ps1' })
if ($proc.Count) {
    $pr = Get-Process -Id $proc[0].ProcessId
    Write-Output ("App             running (PID {0}, {1} MB, CPU {2}s)" -f `
        $proc[0].ProcessId, [math]::Round($pr.WorkingSet64/1MB,1), [math]::Round($pr.TotalProcessorTime.TotalSeconds,1))
} else { Write-Output "App             STOPPED" }

$task = Get-ScheduledTask -TaskName 'MergeTacticsTracker' -ErrorAction SilentlyContinue
Write-Output ("Autostart       {0}" -f $(if ($task) { "registered ($($task.State))" } else { "not registered" }))

$Db = if ($Database) { [MtSq]::OpenDb($Database) } else { Open-MtDb }
# Before the first poll every table is empty, so nothing here may index blindly.
$snap = Invoke-MtQuery $Db "SELECT trophies FROM snapshots ORDER BY ts DESC LIMIT 1"
if (-not $snap.Count) {
    Write-Output "Trophies        no reading yet"
    Write-Output "  The first poll has not landed. If this persists, check token.txt and tag.txt."
} else {
    $best = Get-MtState $Db 'best'
    Write-Output ("Trophies        {0}   (best: {1})" -f $snap[0]['trophies'], $(if ($best) { $best } else { '-' }))
    $arena = Get-MtState $Db 'arena'
    Write-Output ("Arena           {0}" -f $(if ($arena) { $arena } else { '-' }))
}
$lp = Get-MtState $Db 'last_poll'
if ($lp) {
    $age = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int]$lp
    Write-Output ("Last read       {0}s ago" -f $age)
    if ($age -gt 600) { Write-Output "  WARNING: nothing collected for over 10 min" }
}
$m = Invoke-MtQuery $Db "SELECT COUNT(*) c FROM matches"
$d = Invoke-MtQuery $Db "SELECT COUNT(*) c FROM matches WHERE certain=0"
Write-Output ("Matches         {0} ({1} from a spaced reading)" -f $m[0]['c'], $d[0]['c'])
$cal = Invoke-MtQuery $Db "SELECT COUNT(*) c FROM matches WHERE certain=1 AND sample_s<=60"
Write-Output ("Calibration     {0}/5 samples - {1}" -f $cal[0]['c'],
    $(if ([int]$cal[0]['c'] -ge 5) { 'idle interval unlocked' } else { 'fixed 60s (correct)' }))
$p = Get-MtPaths
if (Test-Path $p.Alert) { Write-Output ""; Write-Output "PENDING ALERT:"; Get-Content $p.Alert }
[MtSq]::CloseDb($Db)
