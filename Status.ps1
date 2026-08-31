# Diagnostico rapido: o app esta coletando?
. "$PSScriptRoot\MtLib.ps1"
$proc = @(Get-CimInstance Win32_Process -Filter 'Name="powershell.exe"' |
          Where-Object { $_.CommandLine -like '*MergeTactics.ps1*' })
if ($proc.Count) {
    $pr = Get-Process -Id $proc[0].ProcessId
    Write-Output ("App             rodando (PID {0}, {1} MB, CPU {2}s)" -f `
        $proc[0].ProcessId, [math]::Round($pr.WorkingSet64/1MB,1), [math]::Round($pr.TotalProcessorTime.TotalSeconds,1))
} else { Write-Output "App             PARADO" }

$t = Get-ScheduledTask -TaskName 'MergeTacticsTracker' -ErrorAction SilentlyContinue
Write-Output ("Início automático {0}" -f $(if ($t) { "registrado ($($t.State))" } else { "não registrado" }))

$Db = Open-MtDb
$snap = Invoke-MtQuery $Db "SELECT trophies FROM snapshots ORDER BY ts DESC LIMIT 1"
$lp = Get-MtState $Db 'last_poll'
Write-Output ("Troféus         {0}   (recorde: {1})" -f $snap[0]['trophies'], (Get-MtState $Db 'best'))
Write-Output ("Arena           {0}" -f (Get-MtState $Db 'arena'))
if ($lp) {
    $age = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int]$lp
    Write-Output ("Última leitura  {0}s atrás" -f $age)
    if ($age -gt 600) { Write-Output "  AVISO: sem coletar há mais de 10 min" }
}
$m = Invoke-MtQuery $Db "SELECT COUNT(*) c FROM matches"
$d = Invoke-MtQuery $Db "SELECT COUNT(*) c FROM matches WHERE certain=0"
Write-Output ("Partidas        {0} ({1} com leitura espaçada)" -f $m[0]['c'], $d[0]['c'])
$cal = Invoke-MtQuery $Db "SELECT COUNT(*) c FROM matches WHERE certain=1 AND sample_s<=60"
Write-Output ("Calibração      {0}/5 amostras — {1}" -f $cal[0]['c'],
    $(if ([int]$cal[0]['c'] -ge 5) { 'intervalo ocioso liberado' } else { '60s fixos (correto)' }))
$p = Get-MtPaths
if (Test-Path $p.Alert) { Write-Output ""; Write-Output "ALERTA PENDENTE:"; Get-Content $p.Alert }
[MtSq]::CloseDb($Db)
