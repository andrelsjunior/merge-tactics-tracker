# MergeTactics.ps1 - mini app de bandeja que coleta e mostra a evolucao da
# conta de Merge Tactics. Fonte unica: API oficial do Clash Royale.
# Um unico processo faz a coleta e a interface.

param([switch]$Hidden, [switch]$Watchdog)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Root 'MtLib.ps1')
. (Join-Path $Root 'MtI18n.ps1')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------- configuracao
# A tag do jogador e o token da API ficam em arquivos fora do repositorio.
# Sem isso o app so serviria a uma conta, e o token vazaria no primeiro commit.
$BaseInterval    = 60      # segundos
$MaxIdleInterval = 180
$IdleAfter       = 1800
$CalibMinSamples = 5

# Instancia unica. Rodar o atalho de novo nao deve criar um segundo coletor
# (dois processos escrevendo no mesmo SQLite): a segunda execucao apenas
# sinaliza a primeira para abrir o painel e encerra.
$script:Mutex = New-Object System.Threading.Mutex($false, 'Local\MergeTacticsTracker')
$script:ShowEvt = New-Object System.Threading.EventWaitHandle(
    $false, [System.Threading.EventResetMode]::AutoReset, 'Local\MergeTacticsShowPanel')
if (-not $script:Mutex.WaitOne(0, $false)) {
    # -Watchdog so confere se ha instancia viva; nunca abre o painel sozinho.
    if (-not $Watchdog) { [void]$script:ShowEvt.Set() }
    exit 0
}
if ($Watchdog) { Write-MtLog 'vigia: nao havia instancia, subindo' }

$P = Get-MtPaths

function Show-MtFaltando([string]$arquivo, [string]$comoObter) {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show(
        "Arquivo nao encontrado:`n$arquivo`n`n$comoObter",
        'Merge Tactics tracker', 'OK', 'Warning')
}

if (-not (Test-Path $P.Token)) {
    Show-MtFaltando $P.Token ("Crie o arquivo com o token da API do Clash Royale.`n" +
        "Gere um em https://developer.clashroyale.com (o token e travado no seu IP).")
    exit 1
}
$Token = (Get-Content $P.Token -Raw).Trim()

if (-not (Test-Path $P.Tag)) {
    Show-MtFaltando $P.Tag ("Crie o arquivo com a tag do jogador, incluindo o #.`n" +
        "Exemplo: #ABC123XYZ  (ela aparece no perfil dentro do jogo).")
    exit 1
}
$PlayerTag = (Get-Content $P.Tag -Raw).Trim()
if ($PlayerTag -notmatch '^#[0-9A-Za-z]+$') {
    Show-MtFaltando $P.Tag "A tag lida foi '$PlayerTag'. Ela precisa comecar com # (exemplo: #ABC123XYZ)."
    exit 1
}

$Db = Open-MtDb

# idioma: o que ficou gravado, senao o do Windows
$langSalvo = Get-MtState $Db 'lang'
$script:MtLang = if ($langSalvo -in @('pt', 'en')) { $langSalvo } else { Get-MtSystemLang }

# estado em memoria
$S = [ordered]@{
    LastSeenTs     = 0
    LastSeenSid    = -1
    LastSeenTro    = -1
    LastChange     = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    LastSuccess    = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    LastWritten    = 0
    CurrentInterval= $BaseInterval
    Errors         = 0
    MissingSeason  = 0
    Paused         = $false
    AlertLast      = @{}
    NextPollAt     = 0
}

# NAO usar (Get-Date -UFormat %s): no PowerShell 5.1 ele devolve o epoch
# deslocado pelo fuso local (3h atrasado aqui), corrompendo gaps e series.
function Now-Unix { [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function Send-MtAlert([string]$Key, [string]$Title, [string]$Body) {
    $now = Now-Unix
    Set-Content -Path $P.Alert -Value "[$(Get-Date -Format 'dd/MM HH:mm')] $Title`r`n$Body" -Encoding UTF8
    if ($S.AlertLast.ContainsKey($Key) -and ($now - $S.AlertLast[$Key]) -lt 3600) { return }
    $S.AlertLast[$Key] = $now
    Write-MtLog "ALERTA: $Title - $Body"
    Show-MtToast $Title $Body
}
function Clear-MtAlert([string]$Key) {
    if ($S.AlertLast.ContainsKey($Key)) { $S.AlertLast.Remove($Key) }
    if (Test-Path $P.Alert) { Remove-Item $P.Alert -ErrorAction SilentlyContinue }
}

# -------------------------------------------------------------------- calibragem
# So afrouxa o intervalo depois que os dados provam qual e o menor espacamento
# real entre partidas. Amostras colhidas em ritmo lento sao descartadas: o gap
# delas e inflado pela propria amostragem e realimentaria a decisao.
function Get-MtSafeIdleInterval {
    $rows = Invoke-MtQuery $Db "SELECT ts FROM matches WHERE certain=1 AND sample_s<=$BaseInterval ORDER BY ts"
    if ($rows.Count -lt $CalibMinSamples) { return $BaseInterval }
    $gaps = @()
    for ($i = 1; $i -lt $rows.Count; $i++) {
        $g = [int]$rows[$i]['ts'] - [int]$rows[$i-1]['ts']
        if ($g -gt 0 -and $g -le 3600) { $gaps += $g }
    }
    if (-not $gaps.Count) { return $BaseInterval }
    [Math]::Max($BaseInterval, [Math]::Min($MaxIdleInterval, [int]($gaps | Measure-Object -Minimum).Minimum / 2))
}
function Get-MtCertaintyThreshold {
    $n = [int](Invoke-MtQuery $Db "SELECT COUNT(*) c FROM matches WHERE certain=1 AND sample_s<=$BaseInterval")[0]['c']
    if ($n -ge $CalibMinSamples) {
        $rows = Invoke-MtQuery $Db "SELECT ts FROM matches WHERE certain=1 AND sample_s<=$BaseInterval ORDER BY ts"
        $gaps = @()
        for ($i = 1; $i -lt $rows.Count; $i++) {
            $g = [int]$rows[$i]['ts'] - [int]$rows[$i-1]['ts']
            if ($g -gt 0 -and $g -le 3600) { $gaps += $g }
        }
        if ($gaps.Count) { return ($gaps | Measure-Object -Minimum).Minimum }
    }
    $BaseInterval * 3
}

# ------------------------------------------------------------------------ coleta
function Invoke-MtPoll {
    if ($S.Paused) { return }
    $ts = Now-Unix
    $url = "https://api.clashroyale.com/v1/players/$($PlayerTag -replace '#','%23')"

    $r = Invoke-MtApi -Url $url -Token $Token -TimeoutSec 20
    if ($r.Status -ne 200) {
        $code = $r.Status
        if ($code -eq 403) {
            Send-MtAlert 'auth' (L 'alert.auth') (L 'alert.auth.body')
            Write-MtEvent $Db 'auth_error' '403 - provavel troca de IP (CIDR lock)'
            return
        }
        if ($code -eq 429) { Write-MtEvent $Db 'rate_limit' '429'; return }
        $S.Errors++
        if (($ts - $S.LastSuccess) -gt 1800) {
            Send-MtAlert 'offline' (L 'alert.off') ((L 'alert.off.body') -f $S.Errors)
        }
        Write-MtEvent $Db 'net_error' "status=$code streak=$($S.Errors)"
        return
    }
    $resp = $r.Data

    $S.Errors = 0
    $S.LastSuccess = $ts
    Clear-MtAlert 'auth'
    Clear-MtAlert 'offline'

    # localiza a temporada de Merge Tactics dentro de progress
    $prog = $null
    if ($resp.ContainsKey('progress')) { $prog = $resp['progress'] }
    $seasonKey = $null
    if ($prog) {
        foreach ($k in $prog.Keys) {
            if ($k -match '(?i)autochess|mergetactics|merge_tactics') {
                if (-not $seasonKey -or $k -gt $seasonKey) { $seasonKey = $k }
            }
        }
    }
    if (-not $seasonKey) {
        $S.MissingSeason++
        if ($S.MissingSeason -ge 10) {
            Send-MtAlert 'noseason' (L 'alert.noseason') (L 'alert.noseason.b')
        }
        Write-MtEvent $Db 'no_season' 'nenhuma chave conhecida em progress'
        return
    }
    $S.MissingSeason = 0

    $node     = $prog[$seasonKey]
    $trophies = [int]$node['trophies']
    $best     = [int]$node['bestTrophies']
    $arena    = if ($node.ContainsKey('arena')) { [string]$node['arena']['name'] } else { $null }
    $sid      = Get-MtSeasonId $Db $seasonKey

    $prevArena = Get-MtState $Db 'arena'
    if ($prevArena -ne $arena) {
        if ($prevArena) {
            Write-MtLog "ARENA: $prevArena -> $arena"
            Write-MtEvent $Db 'arena_change' "$prevArena -> $arena"
            Show-MtToast (L 'toast.arena') ((L 'toast.arena.body') -f $arena, $trophies)
        }
        Set-MtState $Db 'arena' $arena
    }
    Set-MtState $Db 'best'      $best
    Set-MtState $Db 'season'    $seasonKey
    Set-MtState $Db 'last_poll' $ts
    Set-MtState $Db 'name'      ([string]$resp['name'])

    # referencia do delta: memoria, ou ultimo snapshot apos reinicio
    if ($S.LastSeenSid -eq $sid -and $S.LastSeenTs -gt 0) {
        $prevTs = $S.LastSeenTs; $prevTro = $S.LastSeenTro
    } else {
        $row = Invoke-MtQuery $Db "SELECT ts, trophies FROM snapshots WHERE season_id=$sid ORDER BY ts DESC LIMIT 1"
        if (-not $row.Count) {
            Invoke-MtExec $Db "INSERT OR REPLACE INTO snapshots (ts,season_id,trophies) VALUES ($ts,$sid,$trophies)"
            $S.LastSeenTs = $ts; $S.LastSeenSid = $sid; $S.LastSeenTro = $trophies
            $S.LastWritten = $ts; $S.LastChange = $ts
            Write-MtLog "baseline ${seasonKey}: $trophies trofeus ($arena)"
            Write-MtEvent $Db 'baseline' "$seasonKey @ $trophies"
            return
        }
        $prevTs = [int]$row[0]['ts']; $prevTro = [int]$row[0]['trophies']
        if (-not $S.LastWritten) { $S.LastWritten = $prevTs }
    }

    $delta = $trophies - $prevTro

    if ($delta -ne 0 -or ($ts - $S.LastWritten) -ge 3600) {
        Invoke-MtExec $Db "INSERT OR REPLACE INTO snapshots (ts,season_id,trophies) VALUES ($ts,$sid,$trophies)"
        $S.LastWritten = $ts
    }
    $S.LastSeenTs = $ts; $S.LastSeenSid = $sid; $S.LastSeenTro = $trophies

    if ($delta -ne 0) {
        $gap = $ts - $prevTs
        $certain = if ($gap -le (Get-MtCertaintyThreshold)) { 1 } else { 0 }
        Invoke-MtExec $Db ("INSERT OR REPLACE INTO matches (ts,season_id,curr,delta,gap_s,certain,sample_s)" +
                           " VALUES ($ts,$sid,$trophies,$delta,$gap,$certain,$($S.CurrentInterval))")
        $S.LastChange = $ts
        $sign = if ($delta -gt 0) { "+$delta" } else { "$delta" }
        $pos = Get-MtPlacement $delta
        Write-MtLog "PARTIDA $sign -> $trophies (${pos}o)"
        Show-MtToast 'Merge Tactics' ((L 'toast.match') -f (Get-MtOrd $pos), $sign, $trophies, $arena)
    }

    Update-MtTrayIcon
    # O painel nao se atualizava sozinho: o cabecalho (trofeus, recorde,
    # sequencia) ficava congelado no instante em que a janela foi aberta.
    if ($delta -ne 0) { Update-MtPanelData $script:MtPeriod }
}

function Get-MtInterval {
    if ((Now-Unix) - $S.LastChange -gt $IdleAfter) { $S.CurrentInterval = Get-MtSafeIdleInterval }
    else { $S.CurrentInterval = $BaseInterval }
    $S.CurrentInterval
}

# ------------------------------------------------------------------ colocacao
# A API nao devolve a posicao final da partida, so o saldo de trofeus. Mas os
# saldos observados se agrupam em quatro faixas que nao se tocam, e cada faixa
# e uma colocacao:
#
#     1o lugar  >= +18      2o lugar  +1 a +17
#     3o lugar  -1 a -16    4o lugar  <= -17
#
# As fronteiras cairam em faixas vazias do historico real (nenhum saldo perto
# de -16/-17 nem de +17/+18), entao a inferencia e estavel. Ainda assim e
# inferencia: uma leitura marcada como nao confiavel pode somar dois jogos e
# aterrissar na faixa errada.
$script:MtPlaceLabel = @('?', '1o', '2o', '3o', '4o')

function Get-MtPlacement([int]$Delta) {
    if ($Delta -ge 18)  { return 1 }
    if ($Delta -gt 0)   { return 2 }
    if ($Delta -ge -16) { return 3 }
    4
}

# ------------------------------------------------------------------- consultas
# Todas aceitam uma janela temporal ($since = 0 significa "tudo"), para que os
# filtros do painel refiltrem os mesmos dados sem duplicar SQL.

function Get-MtSummary([int]$Since = 0) {
    # O valor atual e o do registro mais novo, venha ele de snapshots ou de
    # matches. Olhar so snapshots deixava o cabecalho um passo atras quando a
    # partida entrava primeiro.
    $cur = Invoke-MtQuery $Db @"
SELECT v FROM (SELECT ts, trophies AS v FROM snapshots
               UNION ALL SELECT ts, curr AS v FROM matches)
ORDER BY ts DESC LIMIT 1
"@
    $trophies = if ($cur.Count) { [int]$cur[0]['v'] } else { 0 }
    # bestTrophies da API demora a virar; o maior valor ja visto localmente e a
    # mais fresca das duas fontes, entao o recorde e o maximo entre elas.
    $pk = Invoke-MtQuery $Db @"
SELECT IFNULL(MAX(v),0) m FROM (SELECT trophies AS v FROM snapshots
                                UNION ALL SELECT curr AS v FROM matches)
"@
    $bestApi = Get-MtState $Db 'best'
    $best = [Math]::Max($(if ($bestApi) { [int]$bestApi } else { 0 }), [int]$pk[0]['m'])
    [ordered]@{
        Name     = (Get-MtState $Db 'name')
        Arena    = (Get-MtState $Db 'arena')
        Best     = $best
        Trophies = $trophies
        Total    = [int](Invoke-MtQuery $Db "SELECT COUNT(*) c FROM matches")[0]['c']
        Streak   = Get-MtStreak
        Recordes = Get-MtStreaks $Since
    }
}

function Get-MtStats([int]$Since = 0) {
    $w = if ($Since -gt 0) { "WHERE ts > $Since" } else { "" }
    $r = Invoke-MtQuery $Db @"
SELECT COUNT(*) n,
       IFNULL(SUM(delta),0) net,
       IFNULL(SUM(CASE WHEN delta > 0 THEN 1 ELSE 0 END),0) up
FROM matches $w
"@
    $n = [int]$r[0]['n']; $net = [int]$r[0]['net']; $up = [int]$r[0]['up']
    $pl = Get-MtPlacements $Since
    [ordered]@{
        N     = $n
        Net   = $net
        Avg   = if ($n) { [math]::Round($net / $n, 1) } else { 0 }
        Up    = if ($n) { [int][math]::Round($up * 100 / $n) } else { 0 }
        Place = $pl.Avg
    }
}

# Distribuicao das colocacoes inferidas no periodo. Devolve tambem a faixa de
# saldo observada em cada posicao: e a prova visivel de que a inferencia bate
# com os dados, e nao um chute.
function Get-MtPlacements([int]$Since = 0) {
    $w = if ($Since -gt 0) { "WHERE ts > $Since" } else { "" }
    $rows = Invoke-MtQuery $Db "SELECT delta, certain FROM matches $w"
    $cnt = @(0, 0, 0, 0, 0)
    $lo  = @(0, 0, 0, 0, 0)
    $hi  = @(0, 0, 0, 0, 0)
    $seen = @($false, $false, $false, $false, $false)
    $dub = 0
    $soma = 0
    foreach ($r in $rows) {
        $d = [int]$r['delta']
        $p = Get-MtPlacement $d
        $cnt[$p]++
        $soma += $p
        if ([int]$r['certain'] -ne 1) { $dub++ }
        if (-not $seen[$p]) { $seen[$p] = $true; $lo[$p] = $d; $hi[$p] = $d }
        else {
            if ($d -lt $lo[$p]) { $lo[$p] = $d }
            if ($d -gt $hi[$p]) { $hi[$p] = $d }
        }
    }
    $tot = $rows.Count
    $out = @()
    for ($p = 1; $p -le 4; $p++) {
        $out += [pscustomobject]@{
            Place = $p
            N     = $cnt[$p]
            Pct   = if ($tot) { [int][math]::Round($cnt[$p] * 100 / $tot) } else { 0 }
            Lo    = $lo[$p]
            Hi    = $hi[$p]
            Seen  = $seen[$p]
        }
    }
    @{
        Rows    = $out
        Total   = $tot
        Duvida  = $dub
        Avg     = if ($tot) { [math]::Round($soma / $tot, 2) } else { 0 }
        Top2Pct = if ($tot) { [int][math]::Round(($cnt[1] + $cnt[2]) * 100 / $tot) } else { 0 }
    }
}

function Get-MtSeries([int]$Since = 0) {
    $w = if ($Since -gt 0) { "WHERE ts > $Since" } else { "" }
    $rows = Invoke-MtQuery $Db @"
SELECT ts, trophies AS v FROM snapshots $w
UNION ALL
SELECT ts, curr AS v FROM matches $w
ORDER BY ts
"@
    # Colapsa repeticoes: o heartbeat horario grava o mesmo valor varias vezes
    # e isso desenhava uma reta longa e falsa no fim da curva. O ultimo ponto
    # e sempre mantido, para a curva chegar ao valor atual.
    $out = @()
    $prev = $null
    $all = @($rows)
    for ($i = 0; $i -lt $all.Count; $i++) {
        $v = [int]$all[$i]['v']
        if ($null -eq $prev -or $v -ne $prev -or $i -eq $all.Count - 1) {
            $out += [pscustomobject]@{ Ts = [int]$all[$i]['ts']; V = $v }
            $prev = $v
        }
    }
    @($out)
}

# Sessoes de jogo: partidas separadas por menos de 30 min pertencem a mesma
# sessao. E a unidade que o jogador realmente percebe ("hoje a noite joguei
# mal"), e nenhuma tela do jogo mostra isso.
function Get-MtSessions([int]$Since = 0, [int]$GapMin = 30) {
    $w = if ($Since -gt 0) { "WHERE ts > $Since" } else { "" }
    $rows = (Invoke-MtQuery $Db "SELECT ts, delta, curr, certain FROM matches $w ORDER BY ts")
    if ($rows.Count -eq 0) { return @() }
    $gap = $GapMin * 60
    $out = @()
    $cur = $null
    foreach ($r in $rows) {
        $ts = [int]$r['ts']; $d = [int]$r['delta']; $c = [int]$r['curr']
        $ct = [int]$r['certain']
        $pl = Get-MtPlacement $d
        # cada sessao carrega as proprias partidas: a aba Sessoes abre a linha
        # e mostra jogo a jogo, sem uma segunda consulta por clique.
        $m = [pscustomobject]@{ Ts = $ts; Delta = $d; Curr = $c; Certain = $ct; Place = $pl }
        if ($null -eq $cur -or ($ts - $cur.End) -gt $gap) {
            if ($cur) { $out += $cur }
            $cur = [pscustomobject]@{
                Start = $ts; End = $ts; N = 1; Net = $d
                Up = $(if ($d -gt 0) { 1 } else { 0 })
                EndTro = $c; StartTro = ($c - $d)
                P = @(0, 0, 0, 0, 0); Matches = @($m)
            }
            $cur.P[$pl] = 1
        } else {
            $cur.End = $ts; $cur.N++; $cur.Net += $d; $cur.EndTro = $c
            if ($d -gt 0) { $cur.Up++ }
            $cur.P[$pl]++
            $cur.Matches += $m
        }
    }
    if ($cur) { $out += $cur }
    foreach ($sx in $out) {
        $sx | Add-Member -NotePropertyName AvgPlace -NotePropertyValue $(
            if ($sx.N) { [math]::Round((($sx.P[1] * 1) + ($sx.P[2] * 2) + ($sx.P[3] * 3) + ($sx.P[4] * 4)) / $sx.N, 2) } else { 0 })
        [array]::Reverse($sx.Matches)
    }
    [array]::Reverse($out)
    @($out)
}

# Desempenho por hora do dia. Revela em que horario o jogador rende mais -
# nenhuma outra fonte cruza isso.
function Get-MtByHour([int]$Since = 0) {
    $off = Get-MtTzOffset
    $w = if ($Since -gt 0) { "WHERE ts > $Since" } else { "" }
    $rows = (Invoke-MtQuery $Db @"
SELECT CAST(strftime('%H', ts + $off, 'unixepoch') AS INTEGER) AS h,
       COUNT(*) AS n, SUM(delta) AS net
FROM matches $w GROUP BY h ORDER BY h
"@)
    $map = @{}
    foreach ($r in $rows) {
        $map[[int]$r['h']] = [pscustomobject]@{ N = [int]$r['n']; Net = [int]$r['net'] }
    }
    $out = @()
    for ($h = 0; $h -lt 24; $h++) {
        if ($map.ContainsKey($h)) {
            $out += [pscustomobject]@{ H = $h; N = $map[$h].N; Net = $map[$h].Net
                                       Avg = [math]::Round($map[$h].Net / $map[$h].N, 1) }
        } else {
            $out += [pscustomobject]@{ H = $h; N = 0; Net = 0; Avg = 0 }
        }
    }
    @($out)
}

# Desempenho por dia da semana.
function Get-MtByWeekday([int]$Since = 0) {
    $off = Get-MtTzOffset
    $w = if ($Since -gt 0) { "WHERE ts > $Since" } else { "" }
    $rows = Invoke-MtQuery $Db @"
SELECT CAST(strftime('%w', ts + $off, 'unixepoch') AS INTEGER) AS d,
       COUNT(*) AS n, SUM(delta) AS net
FROM matches $w GROUP BY d ORDER BY d
"@
    $map = @{}
    foreach ($r in $rows) { $map[[int]$r['d']] = [pscustomobject]@{ N = [int]$r['n']; Net = [int]$r['net'] } }
    $nomes = @(0..6 | ForEach-Object { L "wd.$_" })
    $out = @()
    for ($d = 0; $d -lt 7; $d++) {
        if ($map.ContainsKey($d)) {
            $out += [pscustomobject]@{ D = $nomes[$d]; N = $map[$d].N; Net = $map[$d].Net
                                       Avg = [math]::Round($map[$d].Net / $map[$d].N, 1) }
        } else {
            $out += [pscustomobject]@{ D = $nomes[$d]; N = 0; Net = 0; Avg = 0 }
        }
    }
    , $out
}

# Exporta o historico completo para CSV, para analise fora do app.
function Export-MtCsv([string]$Path) {
    $off = Get-MtTzOffset
    $rows = (Invoke-MtQuery $Db @"
SELECT ts, datetime(ts + $off, 'unixepoch') AS quando, delta, curr, gap_s, certain, sample_s
FROM matches ORDER BY ts
"@)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('timestamp,quando,delta,trofeus,colocacao,gap_s,confiavel,intervalo_s')
    foreach ($r in $rows) {
        $pos = Get-MtPlacement ([int]$r['delta'])
        [void]$sb.AppendLine("$($r['ts']),$($r['quando']),$($r['delta']),$($r['curr']),$pos,$($r['gap_s']),$($r['certain']),$($r['sample_s'])")
    }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding $true))
    $rows.Count
}

# Maior sequencia de vitorias e maior de quedas dentro do periodo. A sequencia
# atual (Get-MtStreak) responde "como estou agora"; estas duas respondem "ate
# onde ja foi", que e o numero que o jogador lembra.
function Get-MtStreaks([int]$Since = 0) {
    $w = if ($Since -gt 0) { "WHERE ts > $Since" } else { "" }
    $rows = Invoke-MtQuery $Db "SELECT delta FROM matches $w ORDER BY ts"
    $maxV = 0; $maxQ = 0; $v = 0; $q = 0
    foreach ($r in $rows) {
        if ([int]$r['delta'] -gt 0) { $v++; $q = 0 } else { $q++; $v = 0 }
        if ($v -gt $maxV) { $maxV = $v }
        if ($q -gt $maxQ) { $maxQ = $q }
    }
    @{ Vitorias = $maxV; Quedas = $maxQ }
}

# Sequencia atual de resultados do mesmo sinal.
function Get-MtStreak {
    $rows = Invoke-MtQuery $Db "SELECT delta FROM matches ORDER BY ts DESC LIMIT 40"
    $all = @($rows)
    if ($all.Count -eq 0) { return @{ N = 0; Up = $true } }
    $up = ([int]$all[0]['delta'] -gt 0)
    $n = 0
    foreach ($r in $all) {
        $isUp = ([int]$r['delta'] -gt 0)
        if ($isUp -ne $up) { break }
        $n++
    }
    @{ N = $n; Up = $up }
}

# O winsqlite3.dll do Windows NAO implementa o modificador 'localtime' das
# funcoes de data (retorna string vazia). Por isso o offset do fuso e somado
# ao timestamp antes de formatar. O Brasil nao usa horario de verao desde
# 2019, entao um offset fixo e correto aqui.
function Get-MtTzOffset {
    [int][System.TimeZoneInfo]::Local.GetUtcOffset([DateTime]::Now).TotalSeconds
}

function Get-MtDaily([int]$Since = 0, [int]$Max = 14) {
    $off = Get-MtTzOffset
    $w = if ($Since -gt 0) { "WHERE ts > $Since" } else { "" }
    $rows = Invoke-MtQuery $Db @"
SELECT date(ts + $off, 'unixepoch') AS d, COUNT(*) AS n, SUM(delta) AS net
FROM matches $w GROUP BY d ORDER BY d DESC LIMIT $Max
"@
    $out = @($rows | ForEach-Object {
        [pscustomobject]@{ D = $_['d']; N = [int]$_['n']; Net = [int]$_['net'] }
    })
    [array]::Reverse($out)
    @($out)
}

function Get-MtWeekly([int]$Since = 0, [int]$Max = 10) {
    $off = Get-MtTzOffset
    $w = if ($Since -gt 0) { "WHERE ts > $Since" } else { "" }
    $rows = Invoke-MtQuery $Db @"
SELECT strftime('%Y-W%W', ts + $off, 'unixepoch') AS wk, COUNT(*) AS n, SUM(delta) AS net
FROM matches $w GROUP BY wk ORDER BY wk DESC LIMIT $Max
"@
    $out = @($rows | ForEach-Object {
        [pscustomobject]@{ D = $_['wk']; N = [int]$_['n']; Net = [int]$_['net'] }
    })
    [array]::Reverse($out)
    @($out)
}

# $Limit = 0 devolve o historico inteiro (a aba Partidas rola por tudo).
function Get-MtRecent([int]$Since = 0, [int]$Limit = 5) {
    $w = if ($Since -gt 0) { "WHERE ts > $Since" } else { "" }
    $lim = if ($Limit -gt 0) { "LIMIT $Limit" } else { "" }
    $rows = Invoke-MtQuery $Db "SELECT ts, delta, curr, certain FROM matches $w ORDER BY ts DESC $lim"
    @($rows | ForEach-Object {
        $d = [int]$_['delta']
        [pscustomobject]@{
            Ts = [int]$_['ts']; Delta = $d
            Curr = [int]$_['curr']; Certain = [int]$_['certain']
            Place = (Get-MtPlacement $d)
        }
    })
}

# ============================================================== interface grafica
. (Join-Path $Root 'MtUi.ps1')

function New-MtTrayIcon([int]$Trophies) {
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.SmoothingMode = 'AntiAlias'
    # disco dourado com o numero em azul-noite: legivel a 16px e coerente
    # com a identidade do jogo
    $br = New-Object System.Drawing.SolidBrush $script:T.Gold
    $g.FillEllipse($br, 0, 0, 15, 15)
    $rim = New-Object System.Drawing.Pen $script:T.BgDeep, 1
    $g.DrawEllipse($rim, 0, 0, 15, 15); $rim.Dispose()
    $txt = if ($Trophies -ge 1000) { [string][math]::Round($Trophies / 1000, 1) } else { [string]$Trophies }
    $f = New-Object System.Drawing.Font 'Segoe UI', 6.5, ([System.Drawing.FontStyle]::Bold)
    $wb = New-Object System.Drawing.SolidBrush $script:T.BgDeep
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $g.DrawString($txt, $f, $wb, (New-Object System.Drawing.RectangleF 0, 0, 16, 16), $sf)
    $g.Dispose(); $br.Dispose(); $f.Dispose(); $wb.Dispose()
    [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

function Update-MtTrayIcon {
    if (-not $script:Tray) { return }
    $s = Get-MtSummary
    $old = $script:Tray.Icon
    $script:Tray.Icon = New-MtTrayIcon $s.Trophies
    if ($old) { $old.Dispose() }
    $tip = "Merge Tactics`n" + ((L 'tray.tip') -f $s.Trophies, $s.Arena)
    if ($tip.Length -gt 62) { $tip = $tip.Substring(0, 62) }
    $script:Tray.Text = $tip
}

# cabecalho: trofeus em destaque, arena como pilula, recorde ao lado
# cabecalho: trofeus em destaque, arena como pilula dourada, recorde ao lado
function New-MtHeader($summary, [int]$w, [int]$h) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Size = New-Object System.Drawing.Size $w, $h
    $p.BackColor = $script:T.Bg
    $p.Tag = $summary
    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = 'AntiAlias'
        $g.TextRenderingHint = 'ClearTypeGridFit'
        $d = $s.Tag

        Draw-MtTrophy $g 0 6 30 $script:T.Gold

        $f1 = New-MtFont 32 'Bold'
        $b1 = New-Object System.Drawing.SolidBrush $script:T.Text
        $g.DrawString([string]$d.Trophies, $f1, $b1, 34, 0)
        $sz = $g.MeasureString([string]$d.Trophies, $f1)
        $f1.Dispose(); $b1.Dispose()

        $x = 34 + $sz.Width + 8
        $fa = New-MtFont 9.5 'Bold'
        $aw = $g.MeasureString($d.Arena, $fa).Width + 26
        $ap = New-MtRoundPath $x 12 $aw 26 13
        $ab = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(42, $script:T.Gold))
        $g.FillPath($ab, $ap); $ab.Dispose()
        $apn = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(110, $script:T.Gold)), 1
        $g.DrawPath($apn, $ap); $apn.Dispose()
        $agb = New-Object System.Drawing.SolidBrush $script:T.Gold
        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
        $g.DrawString($d.Arena, $fa, $agb, (New-Object System.Drawing.RectangleF $x, 12, $aw, 26), $sf)
        $fa.Dispose(); $agb.Dispose(); $ap.Dispose()

        # Recorde: dourado quando voce esta nele agora, com a distancia
        # quando esta abaixo. Antes era so um numero fixo, sem leitura.
        $noTopo = ([int]$d.Trophies -ge [int]$d.Best)
        $fm = New-MtFont 8.5 $(if ($noTopo) { 'Bold' } else { 'Regular' })
        $bm = New-Object System.Drawing.SolidBrush $(if ($noTopo) { $script:T.Gold } else { $script:T.Faint })
        $rtxt = if ($noTopo) { (L 'hdr.record.at') -f $d.Best }
                else { (L 'hdr.record.below') -f $d.Best, ([int]$d.Trophies - [int]$d.Best) }
        $g.DrawString($rtxt, $fm, $bm, 36, 45)
        $fm.Dispose(); $bm.Dispose()

        $fq = New-MtFont 8.5
        $bq = New-Object System.Drawing.SolidBrush $script:T.Faint
        $g.DrawString(((L 'hdr.streaks') -f $d.Recordes.Vitorias, $d.Recordes.Quedas),
                      $fq, $bq, 36, 60)
        $fq.Dispose(); $bq.Dispose()

        # sequencia atual, quando houver
        if ($d.Streak -and $d.Streak.N -gt 1) {
            $sc = if ($d.Streak.Up) { $script:T.Up } else { $script:T.Down }
            $stxt = (L $(if ($d.Streak.Up) { 'hdr.streak.up' } else { 'hdr.streak.down' })) -f $d.Streak.N
            $fs2 = New-MtFont 8.5 'Bold'
            $sw = $g.MeasureString($stxt, $fs2).Width + 22
            $bx = $x + $aw + 8
            $sp2 = New-MtRoundPath $bx 14 $sw 22 11
            $sb = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(40, $sc))
            $g.FillPath($sb, $sp2); $sb.Dispose()
            $spn = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(110, $sc)), 1
            $g.DrawPath($spn, $sp2); $spn.Dispose()
            $stb = New-Object System.Drawing.SolidBrush $sc
            $sf2 = New-Object System.Drawing.StringFormat
            $sf2.Alignment = 'Center'; $sf2.LineAlignment = 'Center'
            $g.DrawString($stxt, $fs2, $stb, (New-Object System.Drawing.RectangleF $bx, 14, $sw, 22), $sf2)
            $fs2.Dispose(); $stb.Dispose(); $sp2.Dispose()
        }
    })
    $p
}

function Show-MtPanel {
    try { Show-MtPanelCore } catch { Write-MtLog "erro ao abrir painel: $_" }
}

function Invoke-MtExport {
    try {
        $dest = Join-Path ([Environment]::GetFolderPath('Desktop')) 'merge-tactics.csv'
        $n = Export-MtCsv $dest
        Show-MtToast 'Merge Tactics' ((L 'toast.export.ok') -f $n)
        Write-MtLog "exportado: $n partidas -> $dest"
    } catch {
        Write-MtLog "falha ao exportar: $_"
        Show-MtToast 'Merge Tactics' (L 'toast.export.err')
    }
}

# Periodos do filtro. Since = 0 significa "todo o historico".
$script:MtPeriods = @(
    @{ Key = '24h'; Chave = 'per.24h'; Secs = 86400 }
    @{ Key = '7d';  Chave = 'per.7d';  Secs = 604800 }
    @{ Key = '30d'; Chave = 'per.30d'; Secs = 2592000 }
    @{ Key = 'all'; Chave = 'per.all'; Secs = 0 }
)
# os rotulos sao resolvidos na abertura do painel, ja no idioma corrente
function Get-MtPeriodOptions {
    @($script:MtPeriods | ForEach-Object { @{ Key = $_.Key; Label = (L $_.Chave); Secs = $_.Secs } })
}
$script:MtPeriod = 'all'
$script:MtPeriodAnterior = 'all'
$script:MtTab = 0

function Get-MtSince([string]$key) {
    $p = $script:MtPeriods | Where-Object { $_.Key -eq $key } | Select-Object -First 1
    if (-not $p -or $p.Secs -eq 0) { return 0 }
    (Now-Unix) - $p.Secs
}

# Recalcula todos os blocos para o periodo escolhido e repinta.
function Update-MtPanelData([string]$periodKey) {
    if (-not $script:Panel -or $script:Panel.IsDisposed) { return }
    $script:MtPeriod = $periodKey
    $since = Get-MtSince $periodKey
    $c = $script:PanelParts
    $st = Get-MtStats $since

    $c.Cards[0].Tag.Value = [string]$st.N
    $c.Cards[1].Tag.Value = $(if ($st.Net -ge 0) { "+$($st.Net)" } else { "$($st.Net)" })
    $c.Cards[1].Tag.Color = $(if ($st.Net -ge 0) { $script:T.Up } else { $script:T.Down })
    $c.Cards[2].Tag.Value = $(if ($st.Avg -ge 0) { "+$($st.Avg)" } else { "$($st.Avg)" })
    $c.Cards[2].Tag.Color = $(if ($st.Avg -ge 0) { $script:T.Up } else { $script:T.Down })
    $c.Cards[3].Tag.Value = "$([math]::Round($st.Place, 1))"
    foreach ($card in $c.Cards) { $card.Invalidate() }

    # O cabecalho tem os numeros que mais mudam (trofeus atuais, recorde,
    # sequencia) e nao estava na lista de blocos repintados.
    $c.Header.Tag = Get-MtSummary $since
    $c.Header.Invalidate()

    $c.Chart.Tag = @{ Data = (Get-MtSeries $since); Hover = -1; Pts = @() }
    $c.Chart.Invalidate()
    $c.Daily.Tag  = @{ Data = (Get-MtDaily $since 14);  Caption = 'sec.daily'; Icon = 'cal' }
    $c.Daily.Invalidate()
    $c.Places.Tag = Get-MtPlacements $since
    $c.Places.Invalidate()

    # A repintagem tambem acontece sozinha quando entra uma partida nova. Zerar
    # Scroll aqui arrancaria a lista debaixo de quem estivesse lendo o
    # historico; a posicao so volta ao topo quando o proprio periodo muda.
    $reset = ($periodKey -ne $script:MtPeriodAnterior)
    $script:MtPeriodAnterior = $periodKey
    $rolagem = { param($ctl) if ($reset) { 0 } else { [int]$ctl.Tag.Scroll } }

    $c.List.Tag = @{ Rows = (Get-MtRecent $since 4); Scroll = 0; MaxScroll = 0
                     Titulo = 'sec.recent' }
    $c.List.Invalidate()
    $c.Full.Tag = @{ Rows = (Get-MtRecent $since 0); Scroll = (& $rolagem $c.Full)
                     MaxScroll = [int]$c.Full.Tag.MaxScroll
                     Titulo = 'sec.history' }
    $c.Full.Invalidate()
    $c.Sessions.Tag = @{ Rows = (Get-MtSessions $since); Scroll = (& $rolagem $c.Sessions)
                         MaxScroll = [int]$c.Sessions.Tag.MaxScroll
                         Aberta = $(if ($reset) { -1 } else { [int]$c.Sessions.Tag.Aberta })
                         Hits = @() }
    $c.Sessions.Invalidate()
    $c.Hours.Tag = Get-MtByHour $since
    $c.Hours.Invalidate()
    $c.Wdays.Tag = Get-MtByWeekday $since
    $c.Wdays.Invalidate()
    Update-MtFooter
}

# Alterna entre as abas mostrando/escondendo os blocos de cada uma.
function Set-MtTab([int]$index) {
    $script:MtTab = $index
    $c = $script:PanelParts
    if (-not $c) { return }
    foreach ($x in @($c.Chart, $c.Daily, $c.Places, $c.List)) { $x.Visible = ($index -eq 0) }
    $c.Full.Visible     = ($index -eq 1)
    $c.Sessions.Visible = ($index -eq 2)
    $c.Hours.Visible    = ($index -eq 3)
    $c.Wdays.Visible    = ($index -eq 3)
    if ($c.Tabs.Tag.Sel -ne $index) { $c.Tabs.Tag.Sel = $index; $c.Tabs.Invalidate() }
}

function Update-MtFooter {
    if (-not $script:PanelParts -or -not $script:PanelParts.Footer) { return }
    $lp = Get-MtState $Db 'last_poll'
    $when = if ($lp) { [DateTimeOffset]::FromUnixTimeSeconds([int]$lp).LocalDateTime.ToString('HH:mm:ss') } else { '-' }
    $tot = [int](Invoke-MtQuery $Db "SELECT COUNT(*) c FROM matches")[0]['c']
    $txt = (L 'ft.text') -f $when, $script:LastInterval, $tot
    # Coleta parada e o unico defeito que invalida tudo que o painel mostra;
    # ela precisa aparecer aqui, nao so num toast que ja passou.
    $atraso = if ($lp) { (Now-Unix) - [int]$lp } else { 999999 }
    if ($atraso -gt ($script:LastInterval * 4)) {
        $script:PanelParts.Footer.ForeColor = $script:T.Down
        $txt = ((L 'ft.stopped') -f [int]($atraso / 60)) + $txt
    } else {
        $script:PanelParts.Footer.ForeColor = $script:T.Faint
    }
    $script:PanelParts.Footer.Text = $txt
}

function Show-MtPanelCore {
    if ($script:Panel -and -not $script:Panel.IsDisposed) {
        $script:Panel.Show()
        $script:Panel.WindowState = 'Normal'
        $script:Panel.Activate()
        Update-MtPanelData $script:MtPeriod
        return
    }
    $since = Get-MtSince $script:MtPeriod
    $s = Get-MtSummary $since
    $st = Get-MtStats $since

    $f = New-Object System.Windows.Forms.Form
    $f.Text = "Merge Tactics - $($s.Name) $PlayerTag"
    $f.FormBorderStyle = 'None'          # barra de titulo propria, tema escuro
    $f.Size = New-Object System.Drawing.Size 920, 812
    $f.StartPosition = 'CenterScreen'
    $f.BackColor = $script:T.Bg
    $f.Add_FormClosing({ param($src, $e)
        # fechar esconde: o app segue coletando na bandeja
        if ($e.CloseReason -eq 'UserClosing') { $e.Cancel = $true; $src.Hide() } })

    [void](Add-MtTitleBar $f "$($s.Name)   $PlayerTag")

    $hdr = New-MtHeader $s 440 82
    $hdr.Location = New-Object System.Drawing.Point 26, 62
    $f.Controls.Add($hdr)

    $cardSpecs = @(
        @{ L = (L 'card.matches'); V = [string]$st.N; C = $script:T.Text;  I = 'swords' }
        @{ L = (L 'card.net');     V = $(if ($st.Net -ge 0) { "+$($st.Net)" } else { "$($st.Net)" })
           C = $(if ($st.Net -ge 0) { $script:T.Up } else { $script:T.Down }); I = 'trophy' }
        @{ L = (L 'card.avg');     V = $(if ($st.Avg -ge 0) { "+$($st.Avg)" } else { "$($st.Avg)" })
           C = $(if ($st.Avg -ge 0) { $script:T.Up } else { $script:T.Down }); I = 'chart' }
        @{ L = (L 'card.place');   V = "$([math]::Round($st.Place, 1))"; C = $script:T.Text; I = 'crown' }
    )
    $cards = @()
    $cx = 484
    foreach ($sp in $cardSpecs) {
        $c = New-MtStatCard $sp.L $sp.V $sp.C $sp.I 100 74
        $c.Location = New-Object System.Drawing.Point $cx, 64
        $f.Controls.Add($c)
        $cards += $c
        $cx += 106
    }

    $filter = New-MtFilterBar (Get-MtPeriodOptions) $script:MtPeriod { param($k) Update-MtPanelData $k } 380 32
    $filter.Location = New-Object System.Drawing.Point 26, 152
    $f.Controls.Add($filter)

    $tabs = New-MtTabs @((L 'tab.overview'), (L 'tab.matches'), (L 'tab.sessions'), (L 'tab.hours')) `
                       $script:MtTab { param($i) Set-MtTab $i } 380 30
    $tabs.Location = New-Object System.Drawing.Point 514, 153
    $f.Controls.Add($tabs)

    $chart = New-MtAreaChart (Get-MtSeries $since) 868 214
    $chart.Location = New-Object System.Drawing.Point 26, 196
    $f.Controls.Add($chart)

    $daily = New-MtBars (Get-MtDaily $since 14) 422 176 'sec.daily' 'cal'
    $daily.Location = New-Object System.Drawing.Point 26, 422
    $f.Controls.Add($daily)

    $places = New-MtPlacementChart (Get-MtPlacements $since) 422 176
    $places.Location = New-Object System.Drawing.Point 472, 422
    $f.Controls.Add($places)

    $list = New-MtMatchList (Get-MtRecent $since 4) 868 170
    $list.Location = New-Object System.Drawing.Point 26, 610
    $f.Controls.Add($list)

    # aba Partidas: o historico inteiro, rolavel
    $full = New-MtMatchList (Get-MtRecent $since 0) 868 584 'sec.history'
    $full.Location = New-Object System.Drawing.Point 26, 196
    $full.Visible = $false
    $f.Controls.Add($full)

    # aba Sessoes e aba Horarios ocupam a mesma area dos blocos da visao geral
    $sessions = New-MtSessionList (Get-MtSessions $since) 868 584
    $sessions.Location = New-Object System.Drawing.Point 26, 196
    $sessions.Visible = $false
    $f.Controls.Add($sessions)

    $hours = New-MtHourChart (Get-MtByHour $since) 868 300
    $hours.Location = New-Object System.Drawing.Point 26, 196
    $hours.Visible = $false
    $f.Controls.Add($hours)

    $wdays = New-MtWeekdayChart (Get-MtByWeekday $since) 868 268
    $wdays.Location = New-Object System.Drawing.Point 26, 512
    $wdays.Visible = $false
    $f.Controls.Add($wdays)

    $ft = New-Object System.Windows.Forms.Label
    $ft.ForeColor = $script:T.Faint
    $ft.BackColor = $script:T.Bg
    $ft.Font = New-MtFont 8.5
    $ft.SetBounds(30, 786, 700, 18)
    $f.Controls.Add($ft)

    $f.Add_Paint({
        param($src, $e)
        $g = $e.Graphics
        $g.SmoothingMode = 'AntiAlias'
        $pen = New-Object System.Drawing.Pen $script:T.BorderLit, 1
        $path = New-MtRoundPath 0.5 0.5 ($src.Width - 1) ($src.Height - 1) 12
        $g.DrawPath($pen, $path)
        $pen.Dispose(); $path.Dispose()
    })

    $script:PanelParts = @{
        Cards = $cards; Chart = $chart; Daily = $daily; Header = $hdr
        Places = $places; List = $list; Full = $full; Footer = $ft; Filter = $filter
        Sessions = $sessions; Hours = $hours; Wdays = $wdays; Tabs = $tabs
    }

    # WM_MOUSEWHEEL vai para o controle com foco. Panel nao e selecionavel, entao
    # o handler MouseWheel de cada lista nunca disparava e nada rolava. O Form
    # recebe a mensagem e reencaminha para o bloco que estiver sob o cursor.
    $f.Add_MouseWheel({
        param($src, $e)
        $pt = $src.PointToClient([System.Windows.Forms.Cursor]::Position)
        $ctl = $src.GetChildAtPoint($pt)
        if ($ctl) { Invoke-MtScroll $ctl $e.Delta }
    })
    # Esc fecha (sem encerrar a coleta), F5 recarrega, Ctrl+E exporta
    $f.KeyPreview = $true
    $f.Add_KeyDown({
        param($src, $e)
        if ($e.KeyCode -eq 'Escape') { $src.Hide(); return }
        if ($e.KeyCode -eq 'F5') { Update-MtPanelData $script:MtPeriod; return }
        if ($e.Control -and $e.KeyCode -eq 'E') { Invoke-MtExport; return }
        if ($e.Control -and $e.KeyCode -eq 'L') { Set-MtLang $(if ($script:MtLang -eq 'pt') { 'en' } else { 'pt' }); return }
        # 1..4 trocam de aba sem tirar a mao do teclado
        $n = switch ($e.KeyCode) { 'D1' { 0 } 'D2' { 1 } 'D3' { 2 } 'D4' { 3 } default { -1 } }
        if ($n -ge 0) { Set-MtTab $n }
    })

    $script:Panel = $f
    Set-MtTab $script:MtTab
    Update-MtFooter
    [void]$f.Show()
    $f.Activate()
}

# ------------------------------------------------------------------------ bandeja
$script:Panel = $null
$script:PanelParts = $null
$script:LastInterval = $BaseInterval
$script:Tray = New-Object System.Windows.Forms.NotifyIcon
$script:Tray.Icon = New-MtTrayIcon 0
$script:Tray.Text = 'Merge Tactics'
$script:Tray.Visible = $true

# Troca de idioma: o painel e reconstruido porque rotulos de card, aba e filtro
# sao gravados no controle na criacao, nao lidos a cada repintura.
function Rebuild-MtPanel {
    if (-not $script:Panel -or $script:Panel.IsDisposed) { return }
    $visivel = $script:Panel.Visible
    $velho = $script:Panel
    $script:Panel = $null
    $script:PanelParts = $null
    $velho.Dispose()
    if ($visivel) { Show-MtPanel }
}

function Set-MtLang([string]$lang) {
    if ($lang -eq $script:MtLang) { return }
    $script:MtLang = $lang
    Set-MtState $Db 'lang' $lang
    Write-MtLog "idioma: $lang"
    Update-MtMenuText
    Update-MtTrayIcon
    # A reconstrucao nao pode rodar dentro do handler que a disparou: o form
    # estaria se descartando no meio do proprio evento de teclado, e o proximo
    # Ctrl+L caia no vazio. Um timer de 1ms joga a troca para o tick seguinte
    # do message loop, ja fora do handler.
    if ($script:Panel -and -not $script:Panel.IsDisposed) {
        $adiar = New-Object System.Windows.Forms.Timer
        $adiar.Interval = 1
        $adiar.Add_Tick({
            $this.Stop(); $this.Dispose()
            try { Rebuild-MtPanel } catch { Write-MtLog "erro ao trocar idioma: $_" }
        })
        $adiar.Start()
    }
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen = $menu.Items.Add('');   $miOpen.Add_Click({ Show-MtPanel })
$miNow  = $menu.Items.Add('');   $miNow.Add_Click({ Invoke-MtPoll })
$miExp  = $menu.Items.Add('');   $miExp.Add_Click({ Invoke-MtExport })
$miPause= $menu.Items.Add('')
$miPause.Add_Click({
    $S.Paused = -not $S.Paused
    Update-MtMenuText
})
[void]$menu.Items.Add('-')
$miLang = $menu.Items.Add('')
$miLang.Add_Click({ Set-MtLang $(if ($script:MtLang -eq 'pt') { 'en' } else { 'pt' }) })
[void]$menu.Items.Add('-')
$miExit = $menu.Items.Add('')

function Update-MtMenuText {
    $miOpen.Text  = L 'menu.open'
    $miNow.Text   = L 'menu.now'
    $miExp.Text   = L 'menu.export'
    $miPause.Text = if ($S.Paused) { L 'menu.resume' } else { L 'menu.pause' }
    $miLang.Text  = L 'menu.lang'
    $miExit.Text  = L 'menu.quit'
}
Update-MtMenuText

$miExit.Add_Click({
    $script:Tray.Visible = $false
    [MtSq]::CloseDb($Db)
    try { $script:Mutex.ReleaseMutex() } catch { }
    [System.Windows.Forms.Application]::Exit()
})
$script:Tray.ContextMenuStrip = $menu
$script:Tray.Add_MouseDoubleClick({ Show-MtPanel })

# timer de coleta: dispara a cada 5s e decide se ja e hora de ler
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({
  try {
    if ($script:ShowEvt.WaitOne(0, $false)) { Write-MtLog 'pedido de abrir painel recebido'; Show-MtPanel }
    $now = Now-Unix
    if ($now -ge $S.NextPollAt) {
        try { Invoke-MtPoll } catch { Write-MtLog "erro no poll: $_ (linha $($_.InvocationInfo.ScriptLineNumber))" }
        $script:LastInterval = Get-MtInterval
        $S.NextPollAt = (Now-Unix) + $script:LastInterval
    }
  } catch {
    # Sem este catch a excecao sobe pelo message loop e mata o processo em
    # silencio -- foi assim que ele sumiu em 28/08 as 10:19, sem log.
    Write-MtLog "erro no tick: $_ (linha $($_.InvocationInfo.ScriptLineNumber))"
    $S.NextPollAt = (Now-Unix) + $BaseInterval
  }
})
$timer.Start()

Write-MtLog "app iniciado - tag $PlayerTag"
try { Invoke-MtPoll } catch { Write-MtLog "erro no poll inicial: $_" }
$S.NextPollAt = (Now-Unix) + (Get-MtInterval)
Update-MtTrayIcon

if (-not $Hidden -and -not $Watchdog) { Show-MtPanel }

try {
    [System.Windows.Forms.Application]::Run()
} catch {
    Write-MtLog "MORTE: $_ (linha $($_.InvocationInfo.ScriptLineNumber))"
    throw
} finally {
    Write-MtLog 'app encerrado'
}
