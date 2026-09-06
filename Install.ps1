# Registers both scheduled tasks: the app at logon, and the watchdog that
# restarts it if it dies mid-session.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
# the logon trigger needs the qualified user (DOMAIN\user)
$who = "$env:USERDOMAIN\$env:USERNAME"
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
         -DontStopIfGoingOnBatteries -StartWhenAvailable `
         -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5)

function Register-MtTask([string]$name, [string]$vbs, $trigger, [string]$desc) {
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}"' -f (Join-Path $root $vbs))
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $set `
        -User $who -RunLevel Limited -Description $desc | Out-Null
    Write-Output "Task '$name' registered."
}

Register-MtTask 'MergeTacticsTracker' 'Start.vbs' `
    (New-ScheduledTaskTrigger -AtLogOn -User $who) `
    'Tracks a Merge Tactics account through the official Clash Royale API.'

# Without the watchdog, a mid-session crash goes unnoticed until the next logon.
Register-MtTask 'MergeTacticsWatchdog' 'Watchdog.vbs' `
    (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)) `
    'Restarts the Merge Tactics tracker if no instance is running.'

# A shortcut that opens the panel. Start.vbs with an argument shows it; the
# logon task calls the same script without one and stays in the tray.
$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Merge Tactics.lnk'
$sh = New-Object -ComObject WScript.Shell
$s = $sh.CreateShortcut($lnk)
$s.TargetPath       = Join-Path $env:SystemRoot 'System32\wscript.exe'
$s.Arguments        = '"{0}" show' -f (Join-Path $root 'Start.vbs')
$s.WorkingDirectory = $root
$s.IconLocation     = (Join-Path $root 'mt.ico') + ',0'
$s.Description      = 'Open the Merge Tactics panel'
$s.Save()
Write-Output "Shortcut '$lnk' created."

Write-Output "Start now:  Start-ScheduledTask -TaskName MergeTacticsTracker"
Write-Output "Remove:     .\Uninstall.ps1"
