foreach ($name in @('MergeTacticsTracker', 'MergeTacticsWatchdog', 'MergeTacticsVigia')) {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
}
# -match on the -File form, and never the caller: a plain -like matches any
# process whose command line merely mentions the script, this one included.
Get-CimInstance Win32_Process -Filter 'Name="powershell.exe"' |
  Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match '-[Ff]ile\s+\S*MergeTactics\.ps1' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Merge Tactics.lnk'
if (Test-Path $lnk) { Remove-Item $lnk -ErrorAction SilentlyContinue }
Write-Output "Tasks and shortcut removed. The data in mt.db was preserved."
