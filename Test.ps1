# Test.ps1 - checks the query layer and paints every block off-screen.
# Run it after touching MergeTactics.ps1 or MtUi.ps1:  .\Test.ps1
# A different database can be passed:  .\Test.ps1 -Database C:\path\to\mt.db
# Not -Db: variable names are case-insensitive and that shadows $script:Db.
param([string]$Database = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. "$Root\MtLib.ps1"; . "$Root\MtI18n.ps1"; . "$Root\MtUi.ps1"

# Only the function definitions of the app: running the file would start it.
$errs = $null; $toks = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile("$Root\MergeTactics.ps1", [ref]$toks, [ref]$errs)
$defs = New-Object System.Text.StringBuilder
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    [void]$defs.AppendLine($fn.Extent.Text); [void]$defs.AppendLine()
}
. ([scriptblock]::Create($defs.ToString()))

$script:BaseInterval = 60; $script:MaxIdleInterval = 180; $script:CalibMinSamples = 5
$script:MinGap = @{ Ts = -1; Value = 0; N = 0 }
$script:MtChartPoints = 900
$script:Db = if ($Database) { [MtSq]::OpenDb($Database) } else { Open-MtDb }
$script:MtPeriods = @(
    @{ Key = '24h'; LabelKey = 'per.24h'; Secs = 86400 }
    @{ Key = '7d';  LabelKey = 'per.7d';  Secs = 604800 }
    @{ Key = '30d'; LabelKey = 'per.30d'; Secs = 2592000 }
    @{ Key = 'all'; LabelKey = 'per.all'; Secs = 0 }
)
$script:Failed = 0
function Check([string]$name, [scriptblock]$body) {
    try {
        if (& $body) { Write-Host "  ok    $name" }
        else { Write-Host "  FAIL  $name"; $script:Failed++ }
    } catch { Write-Host "  ERROR $name :: $_"; $script:Failed++ }
}
$total = [int](Invoke-MtQuery $script:Db 'SELECT COUNT(*) c FROM matches')[0]['c']
Write-Host "database: $total matches"

Write-Host "`nplacement inference"
Check 'boundaries land where the rule says' {
    ((Get-MtPlacement 18) -eq 1) -and ((Get-MtPlacement 17) -eq 2) -and ((Get-MtPlacement 1) -eq 2) -and
    ((Get-MtPlacement -1) -eq 3) -and ((Get-MtPlacement -16) -eq 3) -and ((Get-MtPlacement -17) -eq 4)
}
Check 'no recorded delta sits within 2 of a boundary' {
    $near = @((Invoke-MtQuery $script:Db 'SELECT DISTINCT delta FROM matches') |
             ForEach-Object { [int]$_['delta'] } | Where-Object { $_ -in @(16,17,18,19,-15,-16,-17,-18) })
    if ($near.Count) { Write-Host ("        near a boundary: " + ($near -join ', ')) }
    $near.Count -eq 0
}
Check 'the inlined copies agree with Get-MtPlacement' {
    $rows = @(Get-MtRecent 0 0)
    $bad = @($rows | Where-Object { $_.Place -ne (Get-MtPlacement $_.Delta) })
    $bad.Count -eq 0
}

Write-Host "`nquery layer"
Check 'placements add up to the match count' {
    $pl = Get-MtPlacements 0
    (($pl.Rows | Measure-Object -Property N -Sum).Sum -eq $pl.Total) -and ($pl.Total -eq $total)
}
Check 'sessions cover every match exactly once' {
    $ss = @(Get-MtSessions 0)
    (($ss | Measure-Object -Property N -Sum).Sum -eq $total) -and
    (@($ss | Where-Object { ($_.P[1] + $_.P[2] + $_.P[3] + $_.P[4]) -ne $_.N }).Count -eq 0)
}
Check 'a session yields its own matches on demand' {
    $ss = @(Get-MtSessions 0)
    if (-not $ss.Count) { return $true }
    $m = @(Get-MtSessionMatches $ss[0].Start $ss[0].End)
    ($m.Count -eq $ss[0].N) -and ($m[0].Ts -eq $ss[0].End)
}
Check 'season best never trails the highest value seen' {
    $s = Get-MtSummary 0
    [int]$s.Best -ge [int](Invoke-MtQuery $script:Db 'SELECT IFNULL(MAX(curr),0) m FROM matches')[0]['m']
}
Check 'an empty period returns empty, not one phantom row' {
    # past the newest row, not past the clock: a database can hold future stamps
    $future = [int](Invoke-MtQuery $script:Db 'SELECT IFNULL(MAX(ts),0)+1 m FROM matches')[0]['m']
    (@(Get-MtRecent $future 0).Count -eq 0) -and (@(Get-MtSessions $future).Count -eq 0) -and
    ((Get-MtPlacements $future).Total -eq 0) -and ((Get-MtStats $future).N -eq 0)
}
Check 'the chart keeps its ends, its order and its extremes when reduced' {
    $full = @(Get-MtSeries 0 0)
    $cut  = @(Get-MtSeries 0 900)
    if ($full.Count -le 900) { return $cut.Count -eq $full.Count }
    $ordered = $true
    for ($i = 1; $i -lt $cut.Count; $i++) { if ($cut[$i].Ts -lt $cut[$i-1].Ts) { $ordered = $false; break } }
    ($cut.Count -le 902) -and $ordered -and
    ($cut[0].Ts -eq $full[0].Ts) -and ($cut[-1].Ts -eq $full[-1].Ts) -and
    (($cut | Measure-Object -Property V -Minimum).Minimum -eq ($full | Measure-Object -Property V -Minimum).Minimum) -and
    (($cut | Measure-Object -Property V -Maximum).Maximum -eq ($full | Measure-Object -Property V -Maximum).Maximum)
}
Check 'the CSV carries one line per match plus a header' {
    $tmp = Join-Path $env:TEMP 'mt-test.csv'
    $n = Export-MtCsv $tmp
    $lines = @(Get-Content $tmp)
    Remove-Item $tmp -ErrorAction SilentlyContinue
    ($n -eq $total) -and ($lines.Count -eq $total + 1) -and ($lines[0] -like 'timestamp,local_time,*')
}

Write-Host "`nscope: a handler must not be able to shadow the app state"
Check 'every script-scope read is qualified' {
    $src = Get-Content "$Root\MergeTactics.ps1" -Raw
    $names = @('S','P','Db','Token','PlayerTag','BaseInterval','MaxIdleInterval','IdleAfter',
               'CalibMinSamples','Root','miOpen','miNow','miExp','miPause','miTray','miLang','miExit')
    $bad = @($names | Where-Object { [regex]::IsMatch($src, '(?<![:\w])\$' + $_ + '\b') })
    if ($bad.Count) { Write-Host ("        unqualified: " + ($bad -join ', ')) }
    $bad.Count -eq 0
}
Check 'no one-letter names hold state' {
    $src = Get-Content "$Root\MergeTactics.ps1" -Raw
    (-not ($src -cmatch '(?<![:\w])\$S\.')) -and (-not ($src -cmatch '(?<![:\w])\$P\.'))
}

Write-Host "`nstrings"
$used = @('sec.daily', 'sec.history', 'sec.recent')
foreach ($file in @('MtUi.ps1', 'MergeTactics.ps1')) {
    $src = Get-Content "$Root\$file" -Raw
    $used += ([regex]::Matches($src, "L\s+'([a-z0-9.]+)'") | ForEach-Object { $_.Groups[1].Value })
}
$used = @($used | Sort-Object -Unique)
foreach ($lang in @('en', 'pt')) {
    Check "[$lang] all $($used.Count) keys exist" {
        $missing = @($used | Where-Object { -not $script:MtStrings[$lang].ContainsKey($_) })
        if ($missing.Count) { Write-Host ("        missing: " + ($missing -join ', ')) }
        $missing.Count -eq 0
    }
}
Check 'both languages carry the same keys' {
    $d = @(Compare-Object $script:MtStrings['pt'].Keys $script:MtStrings['en'].Keys)
    foreach ($x in $d) { Write-Host "        $($x.SideIndicator) $($x.InputObject)" }
    $d.Count -eq 0
}
Check 'placeholders match between languages' {
    $ok = $true
    foreach ($k in $script:MtStrings['pt'].Keys) {
        $a = (([regex]::Matches([string]$script:MtStrings['pt'][$k], '\{(\d+)\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) -join ',')
        $b = (([regex]::Matches([string]$script:MtStrings['en'][$k], '\{(\d+)\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) -join ',')
        if ($a -ne $b) { Write-Host "        $k differs"; $ok = $false }
    }
    $ok
}

Write-Host "`npainting, with data and with none, in both languages"
$future = [int](Invoke-MtQuery $script:Db 'SELECT IFNULL(MAX(ts),0)+1 m FROM matches')[0]['m']
function Paint([scriptblock]$make) {
    $p = & $make
    $bmp = New-Object System.Drawing.Bitmap $p.Width, $p.Height
    $p.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle 0, 0, $p.Width, $p.Height))
    $bmp.Dispose(); $p.Dispose(); $true
}
foreach ($lang in @('en', 'pt')) {
    $script:MtLang = $lang
    foreach ($since in @(0, $future)) {
        $what = if ($since) { 'empty' } else { 'data' }
        Check "[$lang/$what] chart"     { Paint { New-MtAreaChart (Get-MtSeries $since 900) 868 214 } }
        Check "[$lang/$what] per day"   { Paint { New-MtBars (Get-MtDaily $since 14) 422 176 'sec.daily' 'cal' } }
        Check "[$lang/$what] placements"{ Paint { New-MtPlacementChart (Get-MtPlacements $since) 422 176 } }
        Check "[$lang/$what] history"   { Paint { New-MtMatchList (Get-MtRecent $since 0) 868 584 'sec.history' } }
        Check "[$lang/$what] sessions"  { Paint { New-MtSessionList (Get-MtSessions $since) 868 584 { param($a,$b) Get-MtSessionMatches $a $b } } }
        Check "[$lang/$what] by hour"   { Paint { New-MtHourChart (Get-MtByHour $since) 868 300 } }
        Check "[$lang/$what] by weekday"{ Paint { New-MtWeekdayChart (Get-MtByWeekday $since) 868 268 } }
        Check "[$lang/$what] header"    { Paint { New-MtHeader (Get-MtSummary $since) 440 82 } }
    }
}
$script:MtLang = 'en'
Check 'an expanded session paints its matches' {
    $p = New-MtSessionList (Get-MtSessions 0) 868 584 { param($a,$b) Get-MtSessionMatches $a $b }
    $p.Tag.Expanded = 0
    $bmp = New-Object System.Drawing.Bitmap $p.Width, $p.Height
    $p.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle 0, 0, $p.Width, $p.Height))
    $filled = ($null -ne $p.Tag.Rows[0].Matches)
    $bmp.Dispose(); $p.Dispose()
    $filled
}

Write-Host "`nscrolling"
Check 'the position is clamped and written back when the list shrinks' {
    $p = New-MtMatchList (Get-MtRecent 0 0) 868 584 'sec.history'
    $bmp = New-Object System.Drawing.Bitmap $p.Width, $p.Height
    $rect = New-Object System.Drawing.Rectangle 0, 0, $p.Width, $p.Height
    $p.DrawToBitmap($bmp, $rect)
    Invoke-MtScroll $p -600 999
    $far = [int]$p.Tag.Scroll
    $p.Tag.Rows = @(Get-MtRecent 0 3)
    $p.DrawToBitmap($bmp, $rect)
    $back = [int]$p.Tag.Scroll
    $bmp.Dispose(); $p.Dispose()
    ($far -ge 0) -and ($back -eq 0)
}
Check 'a block without a scroll position is left alone' {
    $p = New-MtBars (Get-MtDaily 0 14) 422 176 'sec.daily' 'cal'
    Invoke-MtScroll $p -240
    $p.Dispose(); $true
}

[MtSq]::CloseDb($script:Db)
Write-Host ""
if ($script:Failed) { Write-Host "$script:Failed FAILED"; exit 1 } else { Write-Host "all checks passed"; exit 0 }
