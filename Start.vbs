' Starts the tracker with no console window.
' With an argument it opens the panel, which is what the desktop shortcut wants.
' Without one the app comes up in the tray only, which is what the logon task
' wants. Either way, if an instance is already running the second process just
' signals it to show the panel and exits.
Set sh = CreateObject("WScript.Shell")
base = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
extra = ""
If WScript.Arguments.Count = 0 Then extra = " -Hidden"
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & base & "\MergeTactics.ps1""" & extra, 0, False
