' Checks every few minutes whether the collector is alive and starts it if not.
' Unlike Start.vbs it never opens the panel: if an instance exists, it exits.
Set sh = CreateObject("WScript.Shell")
base = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & base & "\MergeTactics.ps1"" -Watchdog", 0, False
