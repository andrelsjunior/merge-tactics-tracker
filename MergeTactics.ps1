# MergeTactics.ps1 - tray app that collects and shows a Merge Tactics account.
# Only source: the official Clash Royale API. One process does both the
# collection and the interface.

param([switch]$Hidden, [switch]$Watchdog)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $script:Root 'MtLib.ps1')
. (Join-Path $script:Root 'MtI18n.ps1')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# An exception inside a WinForms handler only raised a dialog and left nothing in
# the log, so there was no function or line to investigate afterwards. The .NET
# stack is all interpreter frames; ScriptStackTrace is the one that names them.
[System.Windows.Forms.Application]::add_ThreadException({
    param($src, $e)
    $ex = $e.Exception
    $where = '?'
    if ($ex.PSObject.Properties['ErrorRecord'] -and $ex.ErrorRecord) {
        $where = ($ex.ErrorRecord.ScriptStackTrace -split "`n" | Select-Object -First 4) -join ' <- '
    }
    Write-MtLog ("UI: {0} | {1} | {2}" -f $ex.GetType().Name, $ex.Message, $where)
})
[AppDomain]::CurrentDomain.add_UnhandledException({
    param($src, $e)
    Write-MtLog ("FATAL: {0}" -f $e.ExceptionObject)
})

# ------------------------------------------------------------------ settings
# Player tag and API token live in files outside the repository.
$script:BaseInterval    = 60      # segundos
$script:MaxIdleInterval = 180
$script:IdleAfter       = 1800
$script:CalibMinSamples = 5

# Single instance. Running the shortcut again must not create a second collector
# writing to the same SQLite file: it signals the first one to open the panel.
$script:Mutex = New-Object System.Threading.Mutex($false, 'Local\MergeTacticsTracker')
$script:ShowEvt = New-Object System.Threading.EventWaitHandle(
    $false, [System.Threading.EventResetMode]::AutoReset, 'Local\MergeTacticsShowPanel')
if (-not $script:Mutex.WaitOne(0, $false)) {
    # -Watchdog only checks for a live instance; it never opens the panel.
    if (-not $Watchdog) { [void]$script:ShowEvt.Set() }
    exit 0
}
if ($Watchdog) { Write-MtLog 'watchdog: no instance found, starting' }

$script:Paths = Get-MtPaths

function Show-MtMissingFile([string]$file, [string]$howTo) {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show(
        "File not found:`n$file`n`n$howTo",
        'Merge Tactics tracker', 'OK', 'Warning')
}

if (-not (Test-Path $script:Paths.Token)) {
    Show-MtMissingFile $script:Paths.Token ("Create it with your Clash Royale API token.`n" +
        "Generate one at https://developer.clashroyale.com (the token is IP-locked).")
    exit 1
}
$script:Token = (Get-Content $script:Paths.Token -Raw).Trim()

if (-not (Test-Path $script:Paths.Tag)) {
    Show-MtMissingFile $script:Paths.Tag ("Create it with your player tag, including the #.`n" +
        "Example: #ABC123XYZ  (it is shown in your in-game profile).")
    exit 1
}
$script:PlayerTag = (Get-Content $script:Paths.Tag -Raw).Trim()
if ($script:PlayerTag -notmatch '^#[0-9A-Za-z]+$') {
    Show-MtMissingFile $script:Paths.Tag "Read '$script:PlayerTag'. The tag must start with # (example: #ABC123XYZ)."
    exit 1
}

$script:Db = Open-MtDb

# saved language, else the Windows one
$savedLang = Get-MtState $script:Db 'lang'
$script:MtLang = if ($savedLang -in @('pt', 'en')) { $savedLang } else { Get-MtSystemLang }
# Minimising to the tray instead of the taskbar. On by default: the window
# already lives in the tray, so a taskbar button for it is a second home.
$script:MtToTray = ((Get-MtState $script:Db 'to_tray') -ne '0')
# The panel opens on the current season: after a reset, mixing seasons draws a
# cliff instead of a curve.
$filtroSalvo = Get-MtState $script:Db 'season_filter'
$script:MtSeasonId = if ($null -ne $filtroSalvo) { [int]$filtroSalvo } else { -1 }

# In-memory state. Explicitly script-scoped, like every other value the
# functions read: PowerShell resolves an unqualified name by walking the call
# stack, so a handler's own $s would otherwise shadow it.
$script:State = [ordered]@{
    LastSeenTs     = 0
    LastSeenSid    = -1
    LastSeenTro    = -1
    LastChange     = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    LastSuccess    = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    LastWritten    = 0
    CurrentInterval= $script:BaseInterval
    Errors         = 0
    MissingSeason  = 0
    Paused         = $false
    AlertLast      = @{}
    NextPollAt     = 0
}

# NOT (Get-Date -UFormat %s): on PowerShell 5.1 it returns the epoch shifted by
# the local time zone, which corrupts gaps and series.
function Now-Unix { [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function Send-MtAlert([string]$Key, [string]$Title, [string]$Body) {
    $now = Now-Unix
    Set-Content -Path $script:Paths.Alert -Value "[$(Get-Date -Format 'dd/MM HH:mm')] $Title`r`n$Body" -Encoding UTF8
    if ($script:State.AlertLast.ContainsKey($Key) -and ($now - $script:State.AlertLast[$Key]) -lt 3600) { return }
    $script:State.AlertLast[$Key] = $now
    Write-MtLog "ALERT: $Title - $Body"
    Show-MtToast $Title $Body
}
function Clear-MtAlert([string]$Key) {
    if ($script:State.AlertLast.ContainsKey($Key)) { $script:State.AlertLast.Remove($Key) }
    if (Test-Path $script:Paths.Alert) { Remove-Item $script:Paths.Alert -ErrorAction SilentlyContinue }
}

# --------------------------------------------------------------- calibration
# The interval only loosens once the data proves the real minimum spacing
# between matches. Samples taken at a slow pace are discarded: their gap is
# inflated by the sampling itself and would feed back into the decision.
# Both interval decisions need the smallest real spacing between reliable
# matches. It scans the whole history and ran twice a minute, so it is computed
# once and kept until a new match lands.
function Get-MtMinGap {
    if (-not (Test-Path variable:script:MinGap)) { $script:MinGap = @{ Ts = -1; Value = 0; N = 0 } }
    $last = [int](Invoke-MtQuery $script:Db "SELECT IFNULL(MAX(ts),0) m FROM matches")[0]['m']
    if ($script:MinGap.Ts -eq $last) { return $script:MinGap }
    $rows = Invoke-MtQuery $script:Db "SELECT ts FROM matches WHERE certain=1 AND sample_s<=$script:BaseInterval ORDER BY ts"
    $min = 0
    for ($i = 1; $i -lt $rows.Count; $i++) {
        $g = [int]$rows[$i]['ts'] - [int]$rows[$i-1]['ts']
        if ($g -gt 0 -and $g -le 3600 -and ($min -eq 0 -or $g -lt $min)) { $min = $g }
    }
    $script:MinGap = @{ Ts = $last; Value = $min; N = $rows.Count }
    $script:MinGap
}

function Get-MtSafeIdleInterval {
    $m = Get-MtMinGap
    if ($m.N -lt $script:CalibMinSamples -or $m.Value -eq 0) { return $script:BaseInterval }
    [Math]::Max($script:BaseInterval, [Math]::Min($script:MaxIdleInterval, [int]($m.Value / 2)))
}
# A reading can only hide a second match if it covers more time than a match
# takes to play. Comparing it against the smallest gap ever seen between matches
# was wrong: that gap is the polling interval, not a match duration. Once one
# pair of matches landed 60 s apart the threshold became 60, the poll arrives
# every 65, and every single reading was branded uncertain.
function Get-MtCertaintyThreshold([int]$SampleSeconds = 0) {
    $sample = if ($SampleSeconds -gt 0) { $SampleSeconds } else { $script:BaseInterval }
    [Math]::Max($script:BaseInterval * 2, $sample * 2)
}

# ------------------------------------------------------------------ collection
function Invoke-MtPoll {
    if ($script:State.Paused) { return }
    $ts = Now-Unix
    $url = "https://api.clashroyale.com/v1/players/$($script:PlayerTag -replace '#','%23')"

    $r = Invoke-MtApi -Url $url -Token $script:Token -TimeoutSec 20
    if ($r.Status -ne 200) {
        $code = $r.Status
        if ($code -eq 403) {
            Send-MtAlert 'auth' (L 'alert.auth') (L 'alert.auth.body')
            Write-MtEvent $script:Db 'auth_error' '403 - likely IP change (CIDR lock)'
            return
        }
        if ($code -eq 429) { Write-MtEvent $script:Db 'rate_limit' '429'; return }
        $script:State.Errors++
        if (($ts - $script:State.LastSuccess) -gt 1800) {
            Send-MtAlert 'offline' (L 'alert.off') ((L 'alert.off.body') -f $script:State.Errors)
        }
        Write-MtEvent $script:Db 'net_error' "status=$code streak=$($script:State.Errors)"
        return
    }
    $resp = $r.Data

    $script:State.Errors = 0
    $script:State.LastSuccess = $ts
    Clear-MtAlert 'auth'
    Clear-MtAlert 'offline'

    # find the Merge Tactics season inside progress
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
        $script:State.MissingSeason++
        if ($script:State.MissingSeason -ge 10) {
            Send-MtAlert 'noseason' (L 'alert.noseason') (L 'alert.noseason.b')
        }
        Write-MtEvent $script:Db 'no_season' 'no known key in progress'
        return
    }
    $script:State.MissingSeason = 0

    $node     = $prog[$seasonKey]
    $trophies = [int]$node['trophies']
    $best     = [int]$node['bestTrophies']
    $arena    = if ($node.ContainsKey('arena')) { [string]$node['arena']['name'] } else { $null }
    $sid      = Get-MtSeasonId $script:Db $seasonKey

    $prevArena = Get-MtState $script:Db 'arena'
    if ($prevArena -ne $arena) {
        if ($prevArena) {
            Write-MtLog "ARENA: $prevArena -> $arena"
            Write-MtEvent $script:Db 'arena_change' "$prevArena -> $arena"
            Show-MtToast (L 'toast.arena') ((L 'toast.arena.body') -f $arena, $trophies)
        }
        Set-MtState $script:Db 'arena' $arena
    }
    Set-MtState $script:Db 'best'      $best
    Set-MtState $script:Db 'season'    $seasonKey
    if ($script:MtSeasonId -lt 0) { $script:MtSeasonId = $sid }
    Set-MtState $script:Db 'last_poll' $ts
    Set-MtState $script:Db 'name'      ([string]$resp['name'])

    # delta reference: memory, or the last snapshot after a restart
    if ($script:State.LastSeenSid -eq $sid -and $script:State.LastSeenTs -gt 0) {
        $prevTs = $script:State.LastSeenTs; $prevTro = $script:State.LastSeenTro
    } else {
        $row = Invoke-MtQuery $script:Db "SELECT ts, trophies FROM snapshots WHERE season_id=$sid ORDER BY ts DESC LIMIT 1"
        if (-not $row.Count) {
            Invoke-MtExec $script:Db "INSERT OR REPLACE INTO snapshots (ts,season_id,trophies) VALUES ($ts,$sid,$trophies)"
            $script:State.LastSeenTs = $ts; $script:State.LastSeenSid = $sid; $script:State.LastSeenTro = $trophies
            $script:State.LastWritten = $ts; $script:State.LastChange = $ts
            Write-MtLog "baseline ${seasonKey}: $trophies trophies ($arena)"
            Write-MtEvent $script:Db 'baseline' "$seasonKey @ $trophies"
            return
        }
        $prevTs = [int]$row[0]['ts']; $prevTro = [int]$row[0]['trophies']
        if (-not $script:State.LastWritten) { $script:State.LastWritten = $prevTs }
    }

    $delta = $trophies - $prevTro

    if ($delta -ne 0 -or ($ts - $script:State.LastWritten) -ge 3600) {
        Invoke-MtExec $script:Db "INSERT OR REPLACE INTO snapshots (ts,season_id,trophies) VALUES ($ts,$sid,$trophies)"
        $script:State.LastWritten = $ts
    }
    $script:State.LastSeenTs = $ts; $script:State.LastSeenSid = $sid; $script:State.LastSeenTro = $trophies

    if ($delta -ne 0) {
        $gap = $ts - $prevTs
        $certain = if ($gap -le (Get-MtCertaintyThreshold $script:State.CurrentInterval)) { 1 } else { 0 }
        Invoke-MtExec $script:Db ("INSERT OR REPLACE INTO matches (ts,season_id,curr,delta,gap_s,certain,sample_s)" +
                           " VALUES ($ts,$sid,$trophies,$delta,$gap,$certain,$($script:State.CurrentInterval))")
        $script:State.LastChange = $ts
        $sign = if ($delta -gt 0) { "+$delta" } else { "$delta" }
        $place = Get-MtPlacement $delta $trophies
        Write-MtLog "MATCH $sign -> $trophies (place $place)"
        Show-MtToast 'Merge Tactics' ((L 'toast.match') -f (Get-MtOrd $place), $sign, $trophies, $arena)
    }

    Update-MtTrayIcon
    # The panel did not refresh itself: the header (trophies, best, streak)
    # stayed frozen at the moment the window was opened.
    if ($delta -ne 0) { Update-MtPanelData $script:MtPeriod }
}

function Get-MtInterval {
    if ((Now-Unix) - $script:State.LastChange -gt $script:IdleAfter) { $script:State.CurrentInterval = Get-MtSafeIdleInterval }
    else { $script:State.CurrentInterval = $script:BaseInterval }
    $script:State.CurrentInterval
}

# ------------------------------------------------------------------- placement
# The API returns no final position, only the trophy delta. The deltas cluster,
# and the clusters say this:
#
#   what you gain does not move with the ladder   2nd +13..+16   1st +25..+38
#   what you lose scales with your trophy count, and 4th always takes about
#   twice what 3rd takes (measured 1.90, 2.17 and 2.22 across three bands)
#
# So the win boundary is fixed and the loss boundary is not. A rule with fixed
# loss thresholds found zero 4th places in 97 matches after a season reset put
# the account back in Bronze. The split is therefore read from the player's own
# history, per trophy band, and shown in the panel so it can be checked.
# Constants the query layer needs. In one function so the app and Test.ps1 cannot
# drift apart: the tests load only the function definitions, and a value defined
# beside them at file scope would be missing there.
function Initialize-MtDefaults {
    $script:MtWinSplit  = 21     # +25..+38 and +13..+16 never came closer than this
    $script:MtLossRatio = 1.5    # 4th takes ~2x 3rd, so the split sits halfway up
    # The Starsteel Road, season 11: thirteen leagues from Bronze I to Diamond.
    # mergetactics.gg/rewards lists the floors, and the arena changes this account
    # recorded confirm them (Bronze II at 200, Bronze III at 400, Silver I at 700,
    # Silver II at 1000). The site also states the shape the data shows: 1st pays
    # about 30 and 2nd about 15 wherever you are, while what 3rd and 4th cost
    # "scales with your current league". So the split is read per band.
    $script:MtBands = @(0, 200, 400, 700, 1000, 1300, 1625, 2025, 2425, 2825, 3225, 3625, 4000)
    $script:MtPlaceModel = $null
    $script:MtPlaceModelAt = -1
    $script:MinGap = @{ Ts = -1; Value = 0; N = 0 }
    if (-not (Test-Path variable:script:MtSeasonId)) { $script:MtSeasonId = 0 }
}
Initialize-MtDefaults

function Get-MtBandIndex([int]$Trophies) {
    $i = 0
    for ($k = 0; $k -lt $script:MtBands.Count; $k++) {
        if ($Trophies -ge $script:MtBands[$k]) { $i = $k } else { break }
    }
    $i
}

# The 3rd/4th split per band, learned from the losses recorded in it. Cached
# until a new match lands, because every row of every list needs it.
function Get-MtPlaceModel {
    $last = [int](Invoke-MtQuery $script:Db "SELECT IFNULL(MAX(ts),0) m FROM matches")[0]['m']
    if ($null -ne $script:MtPlaceModel -and $script:MtPlaceModelAt -eq $last) { return $script:MtPlaceModel }

    $porBanda = @{}
    foreach ($r in (Invoke-MtQuery $script:Db "SELECT curr, delta FROM matches WHERE delta < 0")) {
        $b = Get-MtBandIndex ([int]$r['curr'])
        if (-not $porBanda.ContainsKey($b)) { $porBanda[$b] = New-Object 'System.Collections.Generic.List[int]' }
        $porBanda[$b].Add([Math]::Abs([int]$r['delta']))
    }
    $split = @{}
    foreach ($b in $porBanda.Keys) {
        $v = @($porBanda[$b] | Sort-Object)
        if ($v.Count -lt 6) { continue }
        # widest gap in one dimension: the two clusters are tight and far apart
        $corte = 0; $maior = 0
        for ($i = 1; $i -lt $v.Count; $i++) {
            $gap = $v[$i] - $v[$i-1]
            if ($gap -gt $maior) { $maior = $gap; $corte = ($v[$i-1] + $v[$i]) / 2 }
        }
        $baixo = @($v | Where-Object { $_ -lt $corte })
        $alto  = @($v | Where-Object { $_ -gt $corte })
        # accept only a split that looks like the 2x relationship, otherwise the
        # band saw one placement and the widest gap is just noise
        $bom = $false
        if ($baixo.Count -and $alto.Count) {
            $mb = $baixo[[int]($baixo.Count / 2)]; $ma = $alto[[int]($alto.Count / 2)]
            if ($mb -gt 0 -and ($ma / $mb) -ge 1.6) { $bom = $true }
        }
        $split[$b] = if ($bom) { $corte } else { $v[[int]($v.Count / 4)] * $script:MtLossRatio }
    }
    $script:MtPlaceModel = $split
    $script:MtPlaceModelAt = $last
    $split
}

# The middle of each band, used to place it on the trophy axis. The floor is no
# good for this: the first band starts at zero and any ratio taken from it
# collapses.
function Get-MtBandMid([int]$b) {
    $lo = $script:MtBands[$b]
    $hi = if ($b + 1 -lt $script:MtBands.Count) { $script:MtBands[$b + 1] } else { $lo + 700 }
    ($lo + $hi) / 2
}

# One split per band, every band resolved. Bands the player has never played get
# an interpolation between the two nearest bands that do have history, and the
# result is forced to rise with the trophy count: the loss grows with the ladder,
# so a split that dipped would be an artefact, not a finding.
function Get-MtSplitTable {
    $model = Get-MtPlaceModel
    $n = $script:MtBands.Count
    $tab = New-Object 'double[]' $n
    $sabidos = @($model.Keys | Sort-Object)
    if (-not $sabidos.Count) {
        for ($b = 0; $b -lt $n; $b++) { $tab[$b] = (Get-MtBandMid $b) * 0.007 + 2 }
        return , $tab
    }
    for ($b = 0; $b -lt $n; $b++) {
        if ($model.ContainsKey($b)) { $tab[$b] = [double]$model[$b]; continue }
        $antes = -1; $depois = -1
        foreach ($k in $sabidos) {
            if ($k -lt $b) { $antes = $k }
            elseif ($depois -lt 0) { $depois = $k }
        }
        $meu = Get-MtBandMid $b
        if ($antes -ge 0 -and $depois -ge 0) {
            $ma = Get-MtBandMid $antes; $md = Get-MtBandMid $depois
            $f = ($meu - $ma) / [Math]::Max(1, $md - $ma)
            $tab[$b] = [double]$model[$antes] + $f * ([double]$model[$depois] - [double]$model[$antes])
        } elseif ($antes -ge 0) {
            # above everything played: the loss keeps growing, so scale up
            $tab[$b] = [double]$model[$antes] * $meu / [Math]::Max(1, (Get-MtBandMid $antes))
        } else {
            # below everything played: hold. Down there the trophy floor truncates
            # the loss, so scaling down would push real 3rd places into 4th.
            $tab[$b] = [double]$model[$depois]
        }
    }
    for ($b = 1; $b -lt $n; $b++) { if ($tab[$b] -lt $tab[$b-1]) { $tab[$b] = $tab[$b-1] } }
    , $tab
}

function Get-MtPlacement([int]$Delta, [int]$Trophies = 0) {
    if ($Delta -ge $script:MtWinSplit) { return 1 }
    if ($Delta -gt 0) { return 2 }
    $tab = Get-MtSplitTable
    if ([Math]::Abs($Delta) -lt $tab[(Get-MtBandIndex $Trophies)]) { 3 } else { 4 }
}

# --------------------------------------------------------------------- queries
# All take a time window ($Since = 0 means everything), so the panel filters can
# re-filter the same data without duplicating SQL.

# The season is part of every filter. A reset puts the account back near zero,
# so a chart that mixes seasons draws a cliff that means nothing.
function Get-MtWhere([int]$Since) {
    $c = @()
    if ($Since -gt 0) { $c += "ts > $Since" }
    if ($script:MtSeasonId -gt 0) { $c += "season_id = $script:MtSeasonId" }
    if ($c.Count) { "WHERE " + ($c -join ' AND ') } else { "" }
}

# Seasons the database knows about, newest first, with what was played in each.
function Get-MtSeasons {
    $rows = Invoke-MtQuery $script:Db @"
SELECT s.id, s.key, COUNT(m.ts) AS n, IFNULL(MIN(m.ts),0) AS de, IFNULL(MAX(m.ts),0) AS ate
FROM seasons s LEFT JOIN matches m ON m.season_id = s.id
GROUP BY s.id, s.key ORDER BY s.id DESC
"@
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in $rows) {
        # AutoChess_2026_Season_11 -> "Season 11"
        $rotulo = [string]$r['key']
        if ($rotulo -match 'Season[_ ]?(\d+)') { $rotulo = "$((L 'season.word')) $($Matches[1])" }
        $out.Add([pscustomobject]@{
            Id = [int]$r['id']; Key = [string]$r['key']; Label = $rotulo
            N = [int]$r['n']; From = [int]$r['de']; To = [int]$r['ate']
        })
    }
    $out.ToArray()
}

function Get-MtSummary([int]$Since = 0) {
    # The current value is the newest record, from snapshots or matches. Reading
    # snapshots alone left the header one step behind.
    # One pass over the union instead of two, and one read of state instead of
    # three: this runs on every poll and on every repaint.
    $ws = Get-MtWhere 0
    $agg = Invoke-MtQuery $script:Db @"
SELECT (SELECT v FROM (SELECT ts, trophies AS v FROM snapshots $ws
                       UNION ALL SELECT ts, curr AS v FROM matches $ws)
        ORDER BY ts DESC LIMIT 1) AS atual,
       (SELECT IFNULL(MAX(v),0) FROM (SELECT trophies AS v FROM snapshots $ws
                                      UNION ALL SELECT curr AS v FROM matches $ws)) AS pico,
       (SELECT COUNT(*) FROM matches $ws) AS total
"@
    $trophies = if ($agg.Count -and $agg[0]['atual']) { [int]$agg[0]['atual'] } else { 0 }
    $st = @{}
    foreach ($r in (Invoke-MtQuery $script:Db "SELECT k, v FROM state")) { $st[[string]$r['k']] = $r['v'] }
    # The API's bestTrophies lags, so the best is the max of the two sources.
    $bestApi = if ($st.ContainsKey('best') -and $st['best']) { [int]$st['best'] } else { 0 }
    [ordered]@{
        Name     = $(if ($st.ContainsKey('name')) { $st['name'] } else { $null })
        Arena    = $(if ($st.ContainsKey('arena')) { $st['arena'] } else { $null })
        Best     = [Math]::Max($bestApi, [int]$agg[0]['pico'])
        Trophies = $trophies
        Total    = [int]$agg[0]['total']
        Streak   = Get-MtStreak
        Streaks  = Get-MtStreaks $Since
    }
}

function Get-MtStats([int]$Since = 0) {
    $w = Get-MtWhere $Since
    $r = Invoke-MtQuery $script:Db @"
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

# Distribution of inferred placements, plus the observed delta range for each
# position: visible evidence that the inference matches the data.
function Get-MtPlacements([int]$Since = 0) {
    $w = Get-MtWhere $Since
    $rows = Invoke-MtQuery $script:Db "SELECT curr, delta, certain FROM matches $w"
    $tab = Get-MtSplitTable
    $bandas = $script:MtBands
    $cnt = @(0, 0, 0, 0, 0)
    $lo  = @(0, 0, 0, 0, 0)
    $hi  = @(0, 0, 0, 0, 0)
    $seen = @($false, $false, $false, $false, $false)
    $uncertain = 0
    $sum = 0
    foreach ($r in $rows) {
        $d = [int]$r['delta']; $cu = [int]$r['curr']
        $p = if ($d -ge $script:MtWinSplit) { 1 } elseif ($d -gt 0) { 2 } else {
            $b = 0
            for ($k = 0; $k -lt $bandas.Count; $k++) { if ($cu -ge $bandas[$k]) { $b = $k } else { break } }
            if ([Math]::Abs($d) -lt $tab[$b]) { 3 } else { 4 }
        }
        $cnt[$p]++
        $sum += $p
        if ([int]$r['certain'] -ne 1) { $uncertain++ }
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
    # the split in force where the player is now, so the panel can state it
    $ultimo = Invoke-MtQuery $script:Db "SELECT curr FROM matches $w ORDER BY ts DESC LIMIT 1"
    $onde = if ($ultimo.Count) { [int]$ultimo[0]['curr'] } else { 0 }
    $banda = Get-MtBandIndex $onde
    @{
        Rows    = $out
        Total   = $tot
        Uncertain  = $uncertain
        Avg     = if ($tot) { [math]::Round($sum / $tot, 2) } else { 0 }
        Top2Pct = if ($tot) { [int][math]::Round(($cnt[1] + $cnt[2]) * 100 / $tot) } else { 0 }
        WinSplit  = $script:MtWinSplit
        LossSplit = $tab[$banda]
        Learned   = (Get-MtPlaceModel).ContainsKey($banda)
    }
}

function Get-MtSeries([int]$Since = 0, [int]$MaxPoints = 0) {
    $w = Get-MtWhere $Since
    $rows = Invoke-MtQuery $script:Db @"
SELECT ts, trophies AS v FROM snapshots $w
UNION ALL
SELECT ts, curr AS v FROM matches $w
ORDER BY ts
"@
    # Collapse repeats: the hourly heartbeat writes the same value many times,
    # which drew a long false flat line. The last point is always kept.
    $out = New-Object 'System.Collections.Generic.List[object]'
    $prev = $null
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $v = [int]$rows[$i]['v']
        if ($null -eq $prev -or $v -ne $prev -or $i -eq $rows.Count - 1) {
            $out.Add([pscustomobject]@{ Ts = [int]$rows[$i]['ts']; V = $v })
            $prev = $v
        }
    }
    if ($MaxPoints -le 0 -or $out.Count -le $MaxPoints) { return $out.ToArray() }

    # A season produces thousands of points for a chart 868 pixels wide, and the
    # chart spaces them by index. Each bucket keeps its lowest and highest point,
    # in order, so the peaks survive the reduction.
    # two per slice (the low and the high), plus the real first and last point
    $slices = [Math]::Max(1, [int](($MaxPoints - 2) / 2))
    $res = New-Object 'System.Collections.Generic.List[object]'
    $size = $out.Count / $slices
    for ($b = 0; $b -lt $slices; $b++) {
        $from = [int]($b * $size)
        $to   = [Math]::Min($out.Count - 1, [int](($b + 1) * $size) - 1)
        if ($from -gt $to) { continue }
        $lo = $from; $hi = $from
        for ($i = $from; $i -le $to; $i++) {
            if ($out[$i].V -lt $out[$lo].V) { $lo = $i }
            if ($out[$i].V -gt $out[$hi].V) { $hi = $i }
        }
        if ($lo -eq $hi) { $res.Add($out[$lo]) }
        elseif ($lo -lt $hi) { $res.Add($out[$lo]); $res.Add($out[$hi]) }
        else { $res.Add($out[$hi]); $res.Add($out[$lo]) }
    }
    # the true ends must survive, or the curve starts and ends in the wrong place
    if ($res[0].Ts -ne $out[0].Ts) { $res.Insert(0, $out[0]) }
    if ($res[$res.Count - 1].Ts -ne $out[$out.Count - 1].Ts) { $res.Add($out[$out.Count - 1]) }
    $res.ToArray()
}

# Play sessions: matches less than 30 min apart belong to the same session. That
# is the unit a player actually feels, and no screen in the game shows it.
function Get-MtSessions([int]$Since = 0, [int]$GapMin = 30) {
    $w = Get-MtWhere $Since
    $rows = (Invoke-MtQuery $script:Db "SELECT ts, delta, curr, certain FROM matches $w ORDER BY ts")
    if ($rows.Count -eq 0) { return @() }
    $gap = $GapMin * 60
    $tab = Get-MtSplitTable
    $bandas = $script:MtBands
    # Lists, not arrays: $out += copies the whole array on every append, which
    # turned one season of history into 300 ms of pure copying.
    $out = New-Object 'System.Collections.Generic.List[object]'
    $cur = $null
    foreach ($r in $rows) {
        $ts = [int]$r['ts']; $d = [int]$r['delta']; $c = [int]$r['curr']
        $ct = [int]$r['certain']
        # placement inlined: a function call costs ~8 us and this runs per match
        $pl = if ($d -ge $script:MtWinSplit) { 1 } elseif ($d -gt 0) { 2 } else {
            $b = 0
            for ($k = 0; $k -lt $bandas.Count; $k++) { if ($c -ge $bandas[$k]) { $b = $k } else { break } }
            if ([Math]::Abs($d) -lt $tab[$b]) { 3 } else { 4 }
        }
        if ($null -eq $cur -or ($ts - $cur.End) -gt $gap) {
            if ($cur) { $out.Add($cur) }
            $cur = [pscustomobject]@{
                Start = $ts; End = $ts; N = 1; Net = $d
                Up = $(if ($d -gt 0) { 1 } else { 0 })
                EndTro = $c; StartTro = ($c - $d)
                P = @(0, 0, 0, 0, 0); Matches = $null; AvgPlace = 0
            }
            $cur.P[$pl] = 1
        } else {
            $cur.End = $ts; $cur.N++; $cur.Net += $d; $cur.EndTro = $c
            if ($d -gt 0) { $cur.Up++ }
            $cur.P[$pl]++
        }
    }
    if ($cur) { $out.Add($cur) }
    $all = $out.ToArray()
    foreach ($sx in $all) {
        $sx.AvgPlace = if ($sx.N) {
            [math]::Round((($sx.P[1] * 1) + ($sx.P[2] * 2) + ($sx.P[3] * 3) + ($sx.P[4] * 4)) / $sx.N, 2)
        } else { 0 }
    }
    [array]::Reverse($all)
    $all
}

# The matches of one session, fetched when its row is expanded. Building them
# for every session cost ten times the rest of the tab, to show one.
function Get-MtSessionMatches([int]$Start, [int]$End) {
    $rows = Invoke-MtQuery $script:Db @"
SELECT ts, delta, curr, certain FROM matches
WHERE ts >= $Start AND ts <= $End ORDER BY ts DESC
"@
    $tab = Get-MtSplitTable
    $bandas = $script:MtBands
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in $rows) {
        $d = [int]$r['delta']; $cu = [int]$r['curr']
        $b = 0
        for ($k = 0; $k -lt $bandas.Count; $k++) { if ($cu -ge $bandas[$k]) { $b = $k } else { break } }
        $out.Add([pscustomobject]@{
            Ts = [int]$r['ts']; Delta = $d; Curr = $cu; Certain = [int]$r['certain']
            Place = if ($d -ge $script:MtWinSplit) { 1 } elseif ($d -gt 0) { 2 }
                    elseif ([Math]::Abs($d) -lt $tab[$b]) { 3 } else { 4 }
        })
    }
    $out.ToArray()
}

# Performance by hour of day. No other source crosses these two.
function Get-MtByHour([int]$Since = 0) {
    $off = Get-MtTzOffset
    $w = Get-MtWhere $Since
    $rows = (Invoke-MtQuery $script:Db @"
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

# Performance by weekday.
function Get-MtByWeekday([int]$Since = 0) {
    $off = Get-MtTzOffset
    $w = Get-MtWhere $Since
    $rows = Invoke-MtQuery $script:Db @"
SELECT CAST(strftime('%w', ts + $off, 'unixepoch') AS INTEGER) AS d,
       COUNT(*) AS n, SUM(delta) AS net
FROM matches $w GROUP BY d ORDER BY d
"@
    $map = @{}
    foreach ($r in $rows) { $map[[int]$r['d']] = [pscustomobject]@{ N = [int]$r['n']; Net = [int]$r['net'] } }
    $names = @(0..6 | ForEach-Object { L "wd.$_" })
    $out = @()
    for ($d = 0; $d -lt 7; $d++) {
        if ($map.ContainsKey($d)) {
            $out += [pscustomobject]@{ D = $names[$d]; N = $map[$d].N; Net = $map[$d].Net
                                       Avg = [math]::Round($map[$d].Net / $map[$d].N, 1) }
        } else {
            $out += [pscustomobject]@{ D = $names[$d]; N = 0; Net = 0; Avg = 0 }
        }
    }
    # no leading comma: it would make @(Get-MtByWeekday) one item instead of seven,
    # the way it does for every other query here
    $out
}

# Exports the full history to CSV, for analysis outside the app.
function Export-MtCsv([string]$Path) {
    $off = Get-MtTzOffset
    $rows = (Invoke-MtQuery $script:Db @"
SELECT ts, datetime(ts + $off, 'unixepoch') AS local_time, delta, curr, gap_s, certain, sample_s
FROM matches ORDER BY ts
"@)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('timestamp,local_time,delta,trophies,place,gap_s,reliable,interval_s')
    foreach ($r in $rows) {
        $place = Get-MtPlacement ([int]$r['delta']) ([int]$r['curr'])
        [void]$sb.AppendLine("$($r['ts']),$($r['local_time']),$($r['delta']),$($r['curr']),$place,$($r['gap_s']),$($r['certain']),$($r['sample_s'])")
    }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding $true))
    $rows.Count
}

# Longest win and loss streaks in the period. Get-MtStreak answers "how am I
# doing now"; these two answer "how far did it ever go".
function Get-MtStreaks([int]$Since = 0) {
    $w = Get-MtWhere $Since
    $rows = Invoke-MtQuery $script:Db "SELECT delta FROM matches $w ORDER BY ts"
    $maxWin = 0; $maxLoss = 0; $v = 0; $q = 0
    foreach ($r in $rows) {
        if ([int]$r['delta'] -gt 0) { $v++; $q = 0 } else { $q++; $v = 0 }
        if ($v -gt $maxWin) { $maxWin = $v }
        if ($q -gt $maxLoss) { $maxLoss = $q }
    }
    @{ Wins = $maxWin; Losses = $maxLoss }
}

# Current run of same-signed results.
function Get-MtStreak {
    $rows = Invoke-MtQuery $script:Db "SELECT delta FROM matches $(Get-MtWhere 0) ORDER BY ts DESC LIMIT 40"
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

# Windows' winsqlite3.dll does NOT implement the 'localtime' modifier of the
# date functions (it returns an empty string), so the zone offset is added to the
# timestamp before formatting.
function Get-MtTzOffset {
    [int][System.TimeZoneInfo]::Local.GetUtcOffset([DateTime]::Now).TotalSeconds
}

function Get-MtDaily([int]$Since = 0, [int]$Max = 14) {
    $off = Get-MtTzOffset
    $w = Get-MtWhere $Since
    $rows = Invoke-MtQuery $script:Db @"
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
    $w = Get-MtWhere $Since
    $rows = Invoke-MtQuery $script:Db @"
SELECT strftime('%Y-W%W', ts + $off, 'unixepoch') AS wk, COUNT(*) AS n, SUM(delta) AS net
FROM matches $w GROUP BY wk ORDER BY wk DESC LIMIT $Max
"@
    $out = @($rows | ForEach-Object {
        [pscustomobject]@{ D = $_['wk']; N = [int]$_['n']; Net = [int]$_['net'] }
    })
    [array]::Reverse($out)
    @($out)
}

# $Limit = 0 returns the whole history (the Matches tab scrolls through it).
function Get-MtRecent([int]$Since = 0, [int]$Limit = 5) {
    $w = Get-MtWhere $Since
    $lim = if ($Limit -gt 0) { "LIMIT $Limit" } else { "" }
    $rows = Invoke-MtQuery $script:Db "SELECT ts, delta, curr, certain FROM matches $w ORDER BY ts DESC $lim"
    $tab = Get-MtSplitTable
    $bandas = $script:MtBands
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in $rows) {
        $d = [int]$r['delta']; $cu = [int]$r['curr']
        $b = 0
        for ($k = 0; $k -lt $bandas.Count; $k++) { if ($cu -ge $bandas[$k]) { $b = $k } else { break } }
        $out.Add([pscustomobject]@{
            Ts = [int]$r['ts']; Delta = $d
            Curr = $cu; Certain = [int]$r['certain']
            Place = if ($d -ge $script:MtWinSplit) { 1 } elseif ($d -gt 0) { 2 }
                    elseif ([Math]::Abs($d) -lt $tab[$b]) { 3 } else { 4 }
        })
    }
    $out.ToArray()
}

# =================================================================== interface
. (Join-Path $script:Root 'MtUi.ps1')

function New-MtTrayIcon([int]$Trophies) {
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.SmoothingMode = 'AntiAlias'
    # gold disc with the number in night blue: readable at 16px
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

# Header: trophies, arena pill, season best and the streaks.
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

        # Gold when you are on the record now, with the distance when below.
        $atBest = ([int]$d.Trophies -ge [int]$d.Best)
        $fm = New-MtFont 8.5 $(if ($atBest) { 'Bold' } else { 'Regular' })
        $bm = New-Object System.Drawing.SolidBrush $(if ($atBest) { $script:T.Gold } else { $script:T.Faint })
        $recordText = if ($atBest) { (L 'hdr.record.at') -f $d.Best }
                else { (L 'hdr.record.below') -f $d.Best, ([int]$d.Trophies - [int]$d.Best) }
        $g.DrawString($recordText, $fm, $bm, 36, 45)
        $fm.Dispose(); $bm.Dispose()

        $fq = New-MtFont 8.5
        $bq = New-Object System.Drawing.SolidBrush $script:T.Faint
        $g.DrawString(((L 'hdr.streaks') -f $d.Streaks.Wins, $d.Streaks.Losses),
                      $fq, $bq, 36, 60)
        $fq.Dispose(); $bq.Dispose()

        # current streak, when there is one
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
    try { Show-MtPanelCore } catch { Write-MtLog "failed to open panel: $_" }
}

function Invoke-MtExport {
    try {
        $dest = Join-Path ([Environment]::GetFolderPath('Desktop')) 'merge-tactics.csv'
        $n = Export-MtCsv $dest
        Show-MtToast 'Merge Tactics' ((L 'toast.export.ok') -f $n)
        Write-MtLog "exported: $n matches -> $dest"
    } catch {
        Write-MtLog "export failed: $_"
        Show-MtToast 'Merge Tactics' (L 'toast.export.err')
    }
}

# Filter periods. Secs = 0 means the whole history.
$script:MtPeriods = @(
    @{ Key = '24h'; LabelKey = 'per.24h'; Secs = 86400 }
    @{ Key = '48h'; LabelKey = 'per.48h'; Secs = 172800 }
    @{ Key = '7d';  LabelKey = 'per.7d';  Secs = 604800 }
    @{ Key = '14d'; LabelKey = 'per.14d'; Secs = 1209600 }
    @{ Key = '30d'; LabelKey = 'per.30d'; Secs = 2592000 }
    @{ Key = 'all'; LabelKey = 'per.all'; Secs = 0 }
)
# labels resolve when the panel opens, in the current language
function Get-MtPeriodOptions {
    @($script:MtPeriods | ForEach-Object {
        [pscustomobject]@{ Key = $_.Key; Label = (L $_.LabelKey); Note = '' } })
}

function Get-MtSeasonOptions {
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($t in (Get-MtSeasons)) {
        $out.Add([pscustomobject]@{ Key = [string]$t.Id; Label = $t.Label
                                    Note = (L 'season.matches') -f $t.N })
    }
    $out.Add([pscustomobject]@{ Key = '0'; Label = (L 'season.all'); Note = '' })
    $out.ToArray()
}
$script:MtPeriod = 'all'
$script:MtPeriodPrev = 'all'
$script:MtTab = 0
$script:MtStale = @{ overview = $true; matches = $true; sessions = $true; hours = $true }
# The chart is 868 px wide and spaces its points by index; beyond this they are
# drawn on top of each other.
$script:MtChartPoints = 900

function Get-MtSince([string]$key) {
    $p = $script:MtPeriods | Where-Object { $_.Key -eq $key } | Select-Object -First 1
    if (-not $p -or $p.Secs -eq 0) { return 0 }
    (Now-Unix) - $p.Secs
}

# Recomputes every block for the chosen period and repaints.
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

    # The header holds the numbers that change most and was not in the list of
    # repainted blocks.
    $c.Header.Tag = Get-MtSummary $since
    $c.Header.Invalidate()

    $c.Chart.Tag = @{ Data = (Get-MtSeries $since $script:MtChartPoints); Hover = -1; Pts = @() }
    $c.Chart.Invalidate()
    $c.Daily.Tag  = @{ Data = (Get-MtDaily $since 14);  Caption = 'sec.daily'; Icon = 'cal' }
    $c.Daily.Invalidate()
    $c.Places.Tag = Get-MtPlacements $since
    $c.Places.Invalidate()
    $c.List.Tag = @{ Rows = (Get-MtRecent $since 4); Scroll = 0; MaxScroll = 0
                     Title = 'sec.recent' }
    $c.List.Invalidate()

    # A repaint also happens on its own when a new match arrives. Zeroing Scroll
    # here would yank the list from under whoever is reading the history, so the
    # position only returns to the top when the period itself changes.
    $reset = ($periodKey -ne $script:MtPeriodPrev)
    $script:MtPeriodPrev = $periodKey

    # Only the visible tab is filled in. The other three are marked stale and
    # built when opened: recomputing all four cost close to a second per
    # recorded match once the history reached a season.
    foreach ($k in @($script:MtStale.Keys)) { $script:MtStale[$k] = $true }
    Update-MtTabData $script:MtTab $since $reset
    Update-MtFooter
}

# Switching season invalidates every block, including the ones already built.
function Set-MtSeason([int]$id) {
    if ($id -eq $script:MtSeasonId) { return }
    $script:MtSeasonId = $id
    Set-MtState $script:Db 'season_filter' ([string]$id)
    foreach ($k in @($script:MtStale.Keys)) { $script:MtStale[$k] = $true }
    $script:MtPeriodPrev = ''      # forces the lists back to the top
    Update-MtPanelData $script:MtPeriod
}

# Builds one tab's blocks, if they are stale. Called by Update-MtPanelData for
# the tab in view and by Set-MtTab for whichever is opened next.
function Update-MtTabData([int]$index, [int]$since, [bool]$reset) {
    $c = $script:PanelParts
    if (-not $c) { return }
    $keepScroll = { param($ctl) if ($reset) { 0 } else { [int]$ctl.Tag.Scroll } }

    if ($index -eq 1 -and $script:MtStale['matches']) {
        $c.Full.Tag = @{ Rows = (Get-MtRecent $since 0); Scroll = (& $keepScroll $c.Full)
                         MaxScroll = [int]$c.Full.Tag.MaxScroll
                         Title = 'sec.history' }
        $c.Full.Invalidate()
        $script:MtStale['matches'] = $false
    }
    elseif ($index -eq 2 -and $script:MtStale['sessions']) {
        # The expanded session is found again by start time, not by index: when a
        # new session appears on top the indices slide and the open row jumps.
        $expandedTs = 0
        if (-not $reset) {
            $prevRows = @($c.Sessions.Tag.Rows)
            $prevIdx = [int]$c.Sessions.Tag.Expanded
            if ($prevIdx -ge 0 -and $prevIdx -lt $prevRows.Count) { $expandedTs = [int]$prevRows[$prevIdx].Start }
        }
        $sessions = @(Get-MtSessions $since)
        $expanded = -1
        if ($expandedTs) {
            for ($k = 0; $k -lt $sessions.Count; $k++) {
                if ([int]$sessions[$k].Start -eq $expandedTs) { $expanded = $k; break }
            }
        }
        $c.Sessions.Tag = @{ Rows = $sessions; Scroll = (& $keepScroll $c.Sessions)
                             MaxScroll = [int]$c.Sessions.Tag.MaxScroll
                             Expanded = $expanded; Hits = @(); Fetch = $c.Sessions.Tag.Fetch }
        $c.Sessions.Invalidate()
        $script:MtStale['sessions'] = $false
    }
    elseif ($index -eq 3 -and $script:MtStale['hours']) {
        $c.Hours.Tag = Get-MtByHour $since
        $c.Hours.Invalidate()
        $c.Wdays.Tag = Get-MtByWeekday $since
        $c.Wdays.Invalidate()
        $script:MtStale['hours'] = $false
    }
}

# Switches tabs by showing and hiding each one's blocks.
function Set-MtTab([int]$index) {
    $script:MtTab = $index
    $c = $script:PanelParts
    if (-not $c) { return }
    Update-MtTabData $index (Get-MtSince $script:MtPeriod) $false
    foreach ($x in @($c.Chart, $c.Daily, $c.Places, $c.List)) { $x.Visible = ($index -eq 0) }
    $c.Full.Visible     = ($index -eq 1)
    $c.Sessions.Visible = ($index -eq 2)
    $c.Hours.Visible    = ($index -eq 3)
    $c.Wdays.Visible    = ($index -eq 3)
    if ($c.Tabs.Tag.Sel -ne $index) { $c.Tabs.Tag.Sel = $index; $c.Tabs.Invalidate() }
}

function Update-MtFooter {
    if (-not $script:PanelParts -or -not $script:PanelParts.Footer) { return }
    $lp = Get-MtState $script:Db 'last_poll'
    $when = if ($lp) { [DateTimeOffset]::FromUnixTimeSeconds([int]$lp).LocalDateTime.ToString('HH:mm:ss') } else { '-' }
    $tot = [int](Invoke-MtQuery $script:Db "SELECT COUNT(*) c FROM matches")[0]['c']
    $txt = (L 'ft.text') -f $when, $script:LastInterval, $tot
    # Stopped collection is the one fault that invalidates everything the panel
    # shows, so it belongs here and not only in a toast that already passed.
    $age = if ($lp) { (Now-Unix) - [int]$lp } else { 999999 }
    if ($age -gt ($script:LastInterval * 4)) {
        $script:PanelParts.Footer.ForeColor = $script:T.Down
        $txt = ((L 'ft.stopped') -f [int]($age / 60)) + $txt
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
    $f.Text = "Merge Tactics - $($s.Name) $script:PlayerTag"
    $f.FormBorderStyle = 'None'          # barra de titulo propria, tema escuro
    $f.Size = New-Object System.Drawing.Size 920, 812
    $f.StartPosition = 'CenterScreen'
    $f.BackColor = $script:T.Bg
    $f.Add_FormClosing({ param($src, $e)
        # closing hides: the app keeps collecting in the tray
        if ($e.CloseReason -eq 'UserClosing') { $e.Cancel = $true; $src.Hide() } })

    [void](Add-MtTitleBar $f "$($s.Name)   $script:PlayerTag")

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

    $season = New-MtDropdown (Get-MtSeasonOptions) ([string]$script:MtSeasonId) `
                             { param($k) Set-MtSeason ([int]$k) } 170 30
    $season.Location = New-Object System.Drawing.Point 26, 152
    $f.Controls.Add($season)

    $filter = New-MtDropdown (Get-MtPeriodOptions) $script:MtPeriod `
                             { param($k) Update-MtPanelData $k } 150 30
    $filter.Location = New-Object System.Drawing.Point 204, 152
    $f.Controls.Add($filter)

    $tabs = New-MtTabs @((L 'tab.overview'), (L 'tab.matches'), (L 'tab.sessions'), (L 'tab.hours')) `
                       $script:MtTab { param($i) Set-MtTab $i } 380 30
    $tabs.Location = New-Object System.Drawing.Point 514, 153
    $f.Controls.Add($tabs)

    $chart = New-MtAreaChart (Get-MtSeries $since $script:MtChartPoints) 868 214
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

    # Matches tab: the whole history, scrollable
    $full = New-MtMatchList (Get-MtRecent $since 0) 868 584 'sec.history'
    $full.Location = New-Object System.Drawing.Point 26, 196
    $full.Visible = $false
    $f.Controls.Add($full)

    # the Sessions and Hours tabs occupy the same area as the Overview blocks
    $sessions = New-MtSessionList (Get-MtSessions $since) 868 584 { param($a, $b) Get-MtSessionMatches $a $b }
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
        Places = $places; List = $list; Full = $full; Footer = $ft; Filter = $filter; Season = $season
        Sessions = $sessions; Hours = $hours; Wdays = $wdays; Tabs = $tabs
    }

    # WM_MOUSEWHEEL goes to the focused control and a Panel is not selectable, so
    # each list's own MouseWheel handler never fired. The Form forwards it to the
    # block under the cursor.
    $f.Add_MouseWheel({
        param($src, $e)
        $pt = $src.PointToClient([System.Windows.Forms.Cursor]::Position)
        $ctl = $src.GetChildAtPoint($pt)
        if ($ctl) { Invoke-MtScroll $ctl $e.Delta }
    })
    # Esc hides (collection keeps running), F5 reloads, Ctrl+E exports
    $f.KeyPreview = $true
    $f.Add_KeyDown({
        param($src, $e)
        if ($e.KeyCode -eq 'Escape') { $src.Hide(); return }
        if ($e.KeyCode -eq 'F5') { Update-MtPanelData $script:MtPeriod; return }
        if ($e.Control -and $e.KeyCode -eq 'E') { Invoke-MtExport; return }
        if ($e.Control -and $e.KeyCode -eq 'L') { Set-MtLang $(if ($script:MtLang -eq 'pt') { 'en' } else { 'pt' }); return }
        # 1..4 switch tabs
        $n = switch ($e.KeyCode) { 'D1' { 0 } 'D2' { 1 } 'D3' { 2 } 'D4' { 3 } default { -1 } }
        if ($n -ge 0) { Set-MtTab $n }
    })

    $script:Panel = $f
    Set-MtTab $script:MtTab
    Update-MtFooter
    [void]$f.Show()
    $f.Activate()
}

# ------------------------------------------------------------------------- tray
$script:Panel = $null
$script:PanelParts = $null
$script:LastInterval = $script:BaseInterval
$script:Tray = New-Object System.Windows.Forms.NotifyIcon
$script:Tray.Icon = New-MtTrayIcon 0
$script:Tray.Text = 'Merge Tactics'
$script:Tray.Visible = $true

# Language switch rebuilds the panel: card, tab and filter labels are baked into
# the control at creation, not read on every repaint.
function Rebuild-MtPanel {
    if (-not $script:Panel -or $script:Panel.IsDisposed) { return }
    $wasVisible = $script:Panel.Visible
    $old = $script:Panel
    $script:Panel = $null
    $script:PanelParts = $null
    $old.Dispose()
    if ($wasVisible) { Show-MtPanel }
}

function Set-MtLang([string]$lang) {
    if ($lang -eq $script:MtLang) { return }
    $script:MtLang = $lang
    Set-MtState $script:Db 'lang' $lang
    Write-MtLog "language: $lang"
    Update-MtMenuText
    Update-MtTrayIcon
    # The rebuild cannot run inside the handler that triggered it: the form would
    # dispose itself mid-event and the next Ctrl+L fell through. A 1ms timer moves
    # the switch to the next message-loop tick.
    if ($script:Panel -and -not $script:Panel.IsDisposed) {
        $defer = New-Object System.Windows.Forms.Timer
        $defer.Interval = 1
        $defer.Add_Tick({
            $this.Stop(); $this.Dispose()
            try { Rebuild-MtPanel } catch { Write-MtLog "language switch failed: $_" }
        })
        $defer.Start()
    }
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$script:miOpen = $menu.Items.Add('');   $script:miOpen.Add_Click({ Show-MtPanel })
$script:miNow  = $menu.Items.Add('');   $script:miNow.Add_Click({ Invoke-MtPoll })
$script:miExp  = $menu.Items.Add('');   $script:miExp.Add_Click({ Invoke-MtExport })
$script:miPause= $menu.Items.Add('')
$script:miPause.Add_Click({
    $script:State.Paused = -not $script:State.Paused
    Update-MtMenuText
})
[void]$menu.Items.Add('-')
$script:miTray = $menu.Items.Add('')
$script:miTray.Add_Click({
    $script:MtToTray = -not $script:MtToTray
    Set-MtState $script:Db 'to_tray' $(if ($script:MtToTray) { '1' } else { '0' })
    Update-MtMenuText
})
$script:miLang = $menu.Items.Add('')
$script:miLang.Add_Click({ Set-MtLang $(if ($script:MtLang -eq 'pt') { 'en' } else { 'pt' }) })
[void]$menu.Items.Add('-')
$script:miExit = $menu.Items.Add('')

function Update-MtMenuText {
    $script:miOpen.Text  = L 'menu.open'
    $script:miNow.Text   = L 'menu.now'
    $script:miExp.Text   = L 'menu.export'
    $script:miPause.Text = if ($script:State.Paused) { L 'menu.resume' } else { L 'menu.pause' }
    $script:miTray.Text    = L 'menu.tray'
    $script:miTray.Checked = $script:MtToTray
    $script:miLang.Text  = L 'menu.lang'
    $script:miExit.Text  = L 'menu.quit'
}
Update-MtMenuText

$script:miExit.Add_Click({
    $script:Tray.Visible = $false
    [MtSq]::CloseDb($script:Db)
    try { $script:Mutex.ReleaseMutex() } catch { }
    [System.Windows.Forms.Application]::Exit()
})
$script:Tray.ContextMenuStrip = $menu
$script:Tray.Add_MouseDoubleClick({ Show-MtPanel })

# collection timer: ticks every 5s and decides whether it is time to read
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({
  try {
    if ($script:ShowEvt.WaitOne(0, $false)) { Write-MtLog 'show-panel request received'; Show-MtPanel }
    $now = Now-Unix
    if ($now -ge $script:State.NextPollAt) {
        try { Invoke-MtPoll } catch { Write-MtLog "poll error: $_ (line $($_.InvocationInfo.ScriptLineNumber))" }
        $script:LastInterval = Get-MtInterval
        $script:State.NextPollAt = (Now-Unix) + $script:LastInterval
    }
  } catch {
    # Without this catch the exception climbs the message loop and kills the
    # process silently, leaving nothing in the log.
    Write-MtLog "tick error: $_ (line $($_.InvocationInfo.ScriptLineNumber))"
    $script:State.NextPollAt = (Now-Unix) + $script:BaseInterval
  }
})
$timer.Start()

Write-MtLog "app started - tag $script:PlayerTag"
try { Invoke-MtPoll } catch { Write-MtLog "initial poll error: $_" }
$script:State.NextPollAt = (Now-Unix) + (Get-MtInterval)
Update-MtTrayIcon

if (-not $Hidden -and -not $Watchdog) { Show-MtPanel }

try {
    [System.Windows.Forms.Application]::Run()
} catch {
    Write-MtLog "DIED: $_ (line $($_.InvocationInfo.ScriptLineNumber))"
    throw
} finally {
    Write-MtLog 'app stopped'
}
