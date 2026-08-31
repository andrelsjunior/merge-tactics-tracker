foreach ($name in @('MergeTacticsTracker', 'MergeTacticsWatchdog', 'MergeTacticsVigia')) {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
}
# -match on the -File form, and never the caller: a plain -like matches any
# process whose command line merely mentions the script, this one included.
Get-CimInstance Win32_Process -Filter 'Name="powershell.exe"' |
  Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match '-[Ff]ile\s+\S*MergeTactics\.ps1' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Write-Output "Tasks removed. The data in mt.db was preserved."
