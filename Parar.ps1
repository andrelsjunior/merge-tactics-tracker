Get-CimInstance Win32_Process -Filter 'Name="powershell.exe"' |
  Where-Object { $_.CommandLine -like '*MergeTactics.ps1*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Write-Output "app encerrado"
