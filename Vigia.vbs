' Confere a cada poucos minutos se o coletor esta vivo; sobe se nao estiver.
' Diferente do Iniciar.vbs, nunca abre o painel: se ja ha instancia, sai calado.
Set sh = CreateObject("WScript.Shell")
base = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & base & "\MergeTactics.ps1"" -Watchdog", 0, False
