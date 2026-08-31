Unregister-ScheduledTask -TaskName 'MergeTacticsTracker' -Confirm:$false -ErrorAction SilentlyContinue
Get-Process powershell -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like '*MergeTactics.ps1*' } | Stop-Process -Force -ErrorAction SilentlyContinue
Write-Output "Tarefa removida. Os dados em mt.db foram preservados."
