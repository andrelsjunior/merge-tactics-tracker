# Registra o app para iniciar junto com o Windows (Agendador de Tarefas).
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$vbs  = Join-Path $root 'Iniciar.vbs'
$name = 'MergeTacticsTracker'

$action  = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`""
# o gatilho de logon exige o usuario qualificado (DOMINIO\usuario)
$who = "$env:USERDOMAIN\$env:USERNAME"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $who
$set     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
             -DontStopIfGoingOnBatteries -StartWhenAvailable `
             -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5)

Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $set `
    -User $who -RunLevel Limited `
    -Description 'Coleta a evolucao da conta de Merge Tactics via API oficial do Clash Royale.' | Out-Null

Write-Output "Tarefa '$name' registrada. O app subira no proximo logon."
Write-Output "Para iniciar agora:  Start-ScheduledTask -TaskName $name"
Write-Output "Para remover:        Unregister-ScheduledTask -TaskName $name -Confirm:`$false"
