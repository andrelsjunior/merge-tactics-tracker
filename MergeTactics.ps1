# MergeTactics.ps1 - tray app that collects and shows a Merge Tactics account.
# Only source: the official Clash Royale API. One process does both the
# collection and the interface.

param([switch]$Hidden, [switch]$Watchdog)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Root 'MtLib.ps1')
. (Join-Path $Root 'MtI18n.ps1')

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
$BaseInterval    = 60      # segundos
$MaxIdleInterval = 180
$IdleAfter       = 1800
$CalibMinSamples = 5

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

$P = Get-MtPaths

function Show-MtMissingFile([string]$file, [string]$howTo) {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show(
        "File not found:`n$file`n`n$howTo",
        'Merge Tactics tracker', 'OK', 'Warning')
}

if (-not (Test-Path $P.Token)) {
    Show-MtMissingFile $P.Token ("Create it with your Clash Royale API token.`n" +
        "Generate one at https://developer.clashroyale.com (the token is IP-locked).")
    exit 1
}
$Token = (Get-Content $P.Token -Raw).Trim()

if (-not (Test-Path $P.Tag)) {
    Show-MtMissingFile $P.Tag ("Create it with your player tag, including the #.`n" +
        "Example: #ABC123XYZ  (it is shown in your in-game profile).")
    exit 1
}
$PlayerTag = (Get-Content $P.Tag -Raw).Trim()
if ($PlayerTag -notmatch '^#[0-9A-Za-z]+$') {
    Show-MtMissingFile $P.Tag "Read '$PlayerTag'. The tag must start with # (example: #ABC123XYZ)."
    exit 1
}

$Db = Open-MtDb

# saved language, else the Windows one
$savedLang = Get-MtState $Db 'lang'
$script:MtLang = if ($savedLang -in @('pt', 'en')) { $savedLang } else { Get-MtSystemLang }

# in-memory state
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

# NOT (Get-Date -UFormat %s): on PowerShell 5.1 it returns the epoch shifted by
# the local time zone, which corrupts gaps and series.
function Now-Unix { [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function Send-MtAlert([string]$Key, [string]$Title, [string]$Body) {
    $now = Now-Unix
    Set-Content -Path $P.Alert -Value "[$(Get-Date -Format 'dd/MM HH:mm')] $Title`r`n$Body" -Encoding UTF8
    if ($S.AlertLast.ContainsKey($Key) -and ($now - $S.AlertLast[$Key]) -lt 3600) { return }
    $S.AlertLast[$Key] = $now
    Write-MtLog "ALERT: $Title - $Body"
    Show-MtToast $Title $Body
}
function Clear-MtAlert([string]$Key) {
    if ($S.AlertLast.ContainsKey($Key)) { $S.AlertLast.Remove($Key) }
    if (Test-Path $P.Alert) { Remove-Item $P.Alert -ErrorAction SilentlyContinue }
}

# --------------------------------------------------------------- calibration
# The interval only loosens once the data proves the real minimum spacing
# between matches. Samples taken at a slow pace are discarded: their gap is
# inflated by the sampling itself and would feed back into the decision.
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

# ------------------------------------------------------------------ collection
function Invoke-MtPoll {
    if ($S.Paused) { return }
    $ts = Now-Unix
    $url = "https://api.clashroyale.com/v1/players/$($PlayerTag -replace '#','%23')"

    $r = Invoke-MtApi -Url $url -Token $Token -TimeoutSec 20
    if ($r.Status -ne 200) {
        $code = $r.Status
        if ($code -eq 403) {
            Send-MtAlert 'auth' (L 'alert.auth') (L 'alert.auth.body')
            Write-MtEvent $Db 'auth_error' '403 - likely IP change (CIDR lock)'
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
        $S.MissingSeason++
        if ($S.MissingSeason -ge 10) {
            Send-MtAlert 'noseason' (L 'alert.noseason') (L 'alert.noseason.b')
        }
        Write-MtEvent $Db 'no_season' 'no known key in progress'
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

    # delta reference: memory, or the last snapshot after a restart
    if ($S.LastSeenSid -eq $sid -and $S.LastSeenTs -gt 0) {
        $prevTs = $S.LastSeenTs; $prevTro = $S.LastSeenTro
    } else {
        $row = Invoke-MtQuery $Db "SELECT ts, trophies FROM snapshots WHERE season_id=$sid ORDER BY ts DESC LIMIT 1"
        if (-not $row.Count) {
            Invoke-MtExec $Db "INSERT OR REPLACE INTO snapshots (ts,season_id,trophies) VALUES ($ts,$sid,$trophies)"
            $S.LastSeenTs = $ts; $S.LastSeenSid = $sid; $S.LastSeenTro = $trophies
            $S.LastWritten = $ts; $S.LastChange = $ts
            Write-MtLog "baseline ${seasonKey}: $trophies trophies ($arena)"
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
        $place = Get-MtPlacement $delta
        Write-MtLog "MATCH $sign -> $trophies (place $place)"
        Show-MtToast 'Merge Tactics' ((L 'toast.match') -f (Get-MtOrd $place), $sign, $trophies, $arena)
    }

    Update-MtTrayIcon
    # The panel did not refresh itself: the header (trophies, best, streak)
    # stayed frozen at the moment the window was opened.
    if ($delta -ne 0) { Update-MtPanelData $script:MtPeriod }
}

function Get-MtInterval {
    if ((Now-Unix) - $S.LastChange -gt $IdleAfter) { $S.CurrentInterval = Get-MtSafeIdleInterval }
    else { $S.CurrentInterval = $BaseInterval }
    $S.CurrentInterval
}

# ------------------------------------------------------------------- placement
# The API returns no final position, only the trophy delta. But the observed
# deltas cluster into four bands that do not touch:
#
#     1st  >= +18      2nd  +1 to +17
#     3rd  -1 to -16   4th  <= -17
#
# The boundaries fell in empty stretches of the real history, so the inference is
# stable. It is still inference: a reading flagged as spaced may cover two games
# and land in the wrong band.
$script:MtPlaceLabel = @('?', '1o', '2o', '3o', '4o')

function Get-MtPlacement([int]$Delta) {
    if ($Delta -ge 18)  { return 1 }
    if ($Delta -gt 0)   { return 2 }
    if ($Delta -ge -16) { return 3 }
    4
}

# --------------------------------------------------------------------- queries
# All take a time window ($Since = 0 means everything), so the panel filters can
# re-filter the same data without duplicating SQL.

function Get-MtSummary([int]$Since = 0) {
    # The current value is the newest record, from snapshots or matches. Reading
    # snapshots alone left the header one step behind.
    $cur = Invoke-MtQuery $Db @"
SELECT v FROM (SELECT ts, trophies AS v FROM snapshots
               UNION ALL SELECT ts, curr AS v FROM matches)
ORDER BY ts DESC LIMIT 1
"@
    $trophies = if ($cur.Count) { [int]$cur[0]['v'] } else { 0 }
    # The API's bestTrophies lags, so the best is the max of the two sources.
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
        Streaks = Get-MtStreaks $Since
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

# Distribution of inferred placements, plus the observed delta range for each
# position: visible evidence that the inference matches the data.
function Get-MtPlacements([int]$Since = 0) {
    $w = if ($Since -gt 0) { "WHERE ts > $Since" } else { "" }
    $rows = Invoke-MtQuery $Db "SELECT delta, certain FROM matches $w"
    $cnt = @(0, 0, 0, 0, 0)
    $lo  = @(0, 0, 0, 0, 0)
    $hi  = @(0, 0, 0, 0, 0)
    $seen = @($false, $false, $false, $false, $false)
    $uncertain = 0
    $sum = 0
    foreach ($r in $rows) {
        $d = [int]$r['delta']
        $p = Get-MtPlacement $d
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
    @{
        Rows    = $out
        Total   = $tot
        Uncertain  = $uncertain
        Avg     = if ($tot) { [math]::Round($sum / $tot, 2) } else { 0 }
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
    # Collapse repeats: the hourly heartbeat writes the same value many times,
    # which drew a long false flat line. The last point is always kept.
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

# Play sessions: matches less than 30 min apart belong to the same session. That
# is the unit a player actually feels, and no screen in the game shows it.
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
        # each session carries its own matches, so expanding a row needs no
        # second query
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

# Performance by hour of day. No other source crosses these two.
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

# Performance by weekday.
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
    , $out
}

# Exports the full history to CSV, for analysis outside the app.
function Export-MtCsv([string]$Path) {
    $off = Get-MtTzOffset
    $rows = (Invoke-MtQuery $Db @"
SELECT ts, datetime(ts + $off, 'unixepoch') AS local_time, delta, curr, gap_s, certain, sample_s
FROM matches ORDER BY ts
"@)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('timestamp,local_time,delta,trophies,place,gap_s,reliable,interval_s')
    foreach ($r in $rows) {
        $place = Get-MtPlacement ([int]$r['delta'])
        [void]$sb.AppendLine("$($r['ts']),$($r['local_time']),$($r['delta']),$($r['curr']),$place,$($r['gap_s']),$($r['certain']),$($r['sample_s'])")
    }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding $true))
    $rows.Count
}

# Longest win and loss streaks in the period. Get-MtStreak answers "how am I
# doing now"; these two answer "how far did it ever go".
function Get-MtStreaks([int]$Since = 0) {
    $w = if ($Since -gt 0) { "WHERE ts > $Since" } else { "" }
    $rows = Invoke-MtQuery $Db "SELECT delta FROM matches $w ORDER BY ts"
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

# Windows' winsqlite3.dll does NOT implement the 'localtime' modifier of the
# date functions (it returns an empty string), so the zone offset is added to the
# timestamp before formatting.
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

# $Limit = 0 returns the whole history (the Matches tab scrolls through it).
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

# =================================================================== interface
. (Join-Path $Root 'MtUi.ps1')

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
    @{ Key = '7d';  LabelKey = 'per.7d';  Secs = 604800 }
    @{ Key = '30d'; LabelKey = 'per.30d'; Secs = 2592000 }
    @{ Key = 'all'; LabelKey = 'per.all'; Secs = 0 }
)
# labels resolve when the panel opens, in the current language
function Get-MtPeriodOptions {
    @($script:MtPeriods | ForEach-Object { @{ Key = $_.Key; Label = (L $_.LabelKey); Secs = $_.Secs } })
}
$script:MtPeriod = 'all'
$script:MtPeriodAnterior = 'all'
$script:MtTab = 0

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

    $c.Chart.Tag = @{ Data = (Get-MtSeries $since); Hover = -1; Pts = @() }
    $c.Chart.Invalidate()
    $c.Daily.Tag  = @{ Data = (Get-MtDaily $since 14);  Caption = 'sec.daily'; Icon = 'cal' }
    $c.Daily.Invalidate()
    $c.Places.Tag = Get-MtPlacements $since
    $c.Places.Invalidate()

    # A repaint also happens on its own when a new match arrives. Zeroing Scroll
    # here would yank the list from under whoever is reading the history, so the
    # position only returns to the top when the period itself changes.
    $reset = ($periodKey -ne $script:MtPeriodAnterior)
    $script:MtPeriodAnterior = $periodKey
    $keepScroll = { param($ctl) if ($reset) { 0 } else { [int]$ctl.Tag.Scroll } }

    $c.List.Tag = @{ Rows = (Get-MtRecent $since 4); Scroll = 0; MaxScroll = 0
                     Title = 'sec.recent' }
    $c.List.Invalidate()
    $c.Full.Tag = @{ Rows = (Get-MtRecent $since 0); Scroll = (& $keepScroll $c.Full)
                     MaxScroll = [int]$c.Full.Tag.MaxScroll
                     Title = 'sec.history' }
    $c.Full.Invalidate()
    # The expanded session is found again by start time, not by index: when a new
    # session appears on top the indices slide and the open row would jump.
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
                         Expanded = $expanded; Hits = @() }
    $c.Sessions.Invalidate()
    $c.Hours.Tag = Get-MtByHour $since
    $c.Hours.Invalidate()
    $c.Wdays.Tag = Get-MtByWeekday $since
    $c.Wdays.Invalidate()
    Update-MtFooter
}

# Switches tabs by showing and hiding each one's blocks.
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
    $f.Text = "Merge Tactics - $($s.Name) $PlayerTag"
    $f.FormBorderStyle = 'None'          # barra de titulo propria, tema escuro
    $f.Size = New-Object System.Drawing.Size 920, 812
    $f.StartPosition = 'CenterScreen'
    $f.BackColor = $script:T.Bg
    $f.Add_FormClosing({ param($src, $e)
        # closing hides: the app keeps collecting in the tray
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

    # Matches tab: the whole history, scrollable
    $full = New-MtMatchList (Get-MtRecent $since 0) 868 584 'sec.history'
    $full.Location = New-Object System.Drawing.Point 26, 196
    $full.Visible = $false
    $f.Controls.Add($full)

    # the Sessions and Hours tabs occupy the same area as the Overview blocks
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
$script:LastInterval = $BaseInterval
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
    Set-MtState $Db 'lang' $lang
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

# collection timer: ticks every 5s and decides whether it is time to read
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({
  try {
    if ($script:ShowEvt.WaitOne(0, $false)) { Write-MtLog 'show-panel request received'; Show-MtPanel }
    $now = Now-Unix
    if ($now -ge $S.NextPollAt) {
        try { Invoke-MtPoll } catch { Write-MtLog "poll error: $_ (line $($_.InvocationInfo.ScriptLineNumber))" }
        $script:LastInterval = Get-MtInterval
        $S.NextPollAt = (Now-Unix) + $script:LastInterval
    }
  } catch {
    # Without this catch the exception climbs the message loop and kills the
    # process silently, leaving nothing in the log.
    Write-MtLog "tick error: $_ (line $($_.InvocationInfo.ScriptLineNumber))"
    $S.NextPollAt = (Now-Unix) + $BaseInterval
  }
})
$timer.Start()

Write-MtLog "app started - tag $PlayerTag"
try { Invoke-MtPoll } catch { Write-MtLog "initial poll error: $_" }
$S.NextPollAt = (Now-Unix) + (Get-MtInterval)
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
