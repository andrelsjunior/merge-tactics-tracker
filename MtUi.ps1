# MtUi.ps1 - camada visual do painel. Tudo desenhado com GDI+: os controles
# nativos do WinForms (ListView, borda da janela) nao aceitam tema escuro.
# Paleta inspirada no Clash Royale: azul royal profundo, dourado de trofeu.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class MtWin {
  [DllImport("user32.dll")] public static extern bool ReleaseCapture();
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int m, int w, int l);
  public const int WM_NCLBUTTONDOWN = 0xA1; public const int HTCAPTION = 0x2;
  public static void Drag(IntPtr h){ ReleaseCapture(); SendMessage(h, WM_NCLBUTTONDOWN, HTCAPTION, 0); }
}
"@ -ErrorAction SilentlyContinue

function New-MtColor([int]$r, [int]$g, [int]$b) { [System.Drawing.Color]::FromArgb($r, $g, $b) }

$script:T = @{
    Bg        = New-MtColor 13 21 45      # azul-noite do lobby
    BgDeep    = New-MtColor  9 15 34
    Surface   = New-MtColor 22 34 66
    Raised    = New-MtColor 30 45 84
    Border    = New-MtColor 44 64 110
    BorderLit = New-MtColor 64 92 156
    Text      = New-MtColor 236 242 255
    Dim       = New-MtColor 146 165 205
    Faint     = New-MtColor 100 120 162
    Royal     = New-MtColor  61 122 255   # azul dos botoes do jogo
    Gold      = New-MtColor 255 199  61   # trofeu
    Elixir    = New-MtColor 214  81 224   # roxo do elixir
    Up        = New-MtColor  76 217 100
    Down      = New-MtColor 255  71  87
    Amber     = New-MtColor 255 159  67   # 3o lugar: perde pouco, nao e derrota feia
}

# Cor de cada colocacao. Indice 0 nao e usado, para 1..4 casarem com a posicao.
$script:MtPlaceC = @(
    $script:T.Faint, $script:T.Gold, $script:T.Up, $script:T.Amber, $script:T.Down
)

# Rolagem generica dos blocos de lista.
#
# WM_MOUSEWHEEL vai para o controle COM FOCO, e Panel nao e selecionavel: o
# evento MouseWheel do proprio painel nunca disparava, e por isso nenhuma lista
# rolava. O Form recebe a mensagem e chama esta funcao para o bloco que estiver
# sob o cursor. Cada bloco publica MaxScroll durante o proprio Paint, que e
# quando ele sabe quantas linhas couberam.
function Invoke-MtScroll($panel, [int]$delta, [int]$step = 2) {
    if (-not $panel) { return }
    $st = $panel.Tag
    if (-not ($st -is [System.Collections.Hashtable])) { return }
    if (-not $st.ContainsKey('Scroll')) { return }
    $max = if ($st.ContainsKey('MaxScroll')) { [int]$st.MaxScroll } else { 0 }
    $n = [int]$st.Scroll - ([Math]::Sign($delta) * $step)
    if ($n -lt 0) { $n = 0 }
    if ($n -gt $max) { $n = $max }
    if ($n -ne [int]$st.Scroll) { $st.Scroll = $n; $panel.Invalidate() }
}

# Pilula colorida com a colocacao inferida (1o..4o).
function Draw-MtPlacePill($g, [int]$place, [single]$x, [single]$y, [single]$w, [single]$h, [bool]$duvida = $false) {
    $c = $script:MtPlaceC[$place]
    $path = New-MtRoundPath $x $y $w $h ($h / 2)
    $b = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(46, $c))
    $g.FillPath($b, $path); $b.Dispose()
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(130, $c)), 1
    if ($duvida) { $pen.DashStyle = 'Dot' }
    $g.DrawPath($pen, $path); $pen.Dispose()
    $f = New-MtFont 8.5 'Bold'
    $tb = New-Object System.Drawing.SolidBrush $c
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $txt = Get-MtOrd $place
    $g.DrawString($txt, $f, $tb, (New-Object System.Drawing.RectangleF $x, $y, $w, $h), $sf)
    $f.Dispose(); $tb.Dispose(); $path.Dispose()
}

function New-MtFont([single]$size, [string]$style = 'Regular') {
    New-Object System.Drawing.Font 'Segoe UI', $size, ([System.Drawing.FontStyle]::$style)
}

function New-MtRoundPath([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($r -le 0) { $p.AddRectangle((New-Object System.Drawing.RectangleF $x, $y, $w, $h)); return $p }
    $d = $r * 2
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    $p
}

# Sombra suave: varias bordas arredondadas com alpha decrescente. Da o
# relevo que uma borda de 1px sozinha nao consegue.
function Draw-MtShadow($g, [int]$W, [int]$H, [int]$radius = 14, [int]$depth = 5) {
    for ($i = $depth; $i -ge 1; $i--) {
        $a = [int](16 - $i * 2)
        if ($a -le 0) { continue }
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb($a, 0, 0, 0)), 1
        $sp = New-MtRoundPath ($i * 0.5) ($i * 0.9) ($W - $i) ($H - $i) ($radius + $i)
        $g.DrawPath($pen, $sp)
        $pen.Dispose(); $sp.Dispose()
    }
}

# Fundo padrao dos blocos: gradiente vertical suave, borda, cantos arredondados.
function Draw-MtPanelBg($g, [int]$W, [int]$H, [int]$radius = 14) {
    $path = New-MtRoundPath 0.5 0.5 ($W - 1) ($H - 1) $radius
    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.Point 0, 0),
        (New-Object System.Drawing.Point 0, $H),
        $script:T.Surface, $script:T.BgDeep)
    $g.FillPath($grad, $path); $grad.Dispose()
    # bisel: linha clara no topo, como se a luz viesse de cima
    $hl = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(26, 255, 255, 255)), 1
    $g.DrawArc($hl, 1, 1, ($radius * 2), ($radius * 2), 180, 90)
    $g.DrawLine($hl, ($radius + 1), 1, ($W - $radius - 1), 1)
    $g.DrawArc($hl, ($W - $radius * 2 - 2), 1, ($radius * 2), ($radius * 2), 270, 90)
    $hl.Dispose()
    $pen = New-Object System.Drawing.Pen $script:T.Border, 1
    $g.DrawPath($pen, $path); $pen.Dispose()
    $path
}

# ------------------------------------------------------------------- icones
# Vetoriais: escalam sem borrar e nao dependem de arquivo externo.

function Draw-MtTrophy($g, [single]$x, [single]$y, [single]$s, $color) {
    $b = New-Object System.Drawing.SolidBrush $color
    # copo: boca reta em cima, fundo arredondado embaixo
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddLine(($x + $s * 0.24), ($y + $s * 0.08), ($x + $s * 0.76), ($y + $s * 0.08))
    $p.AddArc(($x + $s * 0.24), ($y + $s * 0.08), ($s * 0.52), ($s * 0.56), 0, 180)
    $p.CloseFigure()
    $g.FillPath($b, $p); $p.Dispose()
    # alcas laterais, finas e coladas no copo
    $pen = New-Object System.Drawing.Pen $color, ($s * 0.07)
    $g.DrawArc($pen, ($x + $s * 0.06), ($y + $s * 0.12), ($s * 0.24), ($s * 0.26), 100, 170)
    $g.DrawArc($pen, ($x + $s * 0.70), ($y + $s * 0.12), ($s * 0.24), ($s * 0.26), 270, 170)
    $pen.Dispose()
    # haste e base
    $g.FillRectangle($b, ($x + $s * 0.44), ($y + $s * 0.60), ($s * 0.12), ($s * 0.16))
    $bp = New-MtRoundPath ($x + $s * 0.28) ($y + $s * 0.76) ($s * 0.44) ($s * 0.14) ($s * 0.04)
    $g.FillPath($b, $bp); $bp.Dispose()
    $b.Dispose()
}

function Draw-MtCrown($g, [single]$x, [single]$y, [single]$s, $color) {
    $b = New-Object System.Drawing.SolidBrush $color
    $pts = @(
        (New-Object System.Drawing.PointF ($x),               ($y + $s * 0.22)),
        (New-Object System.Drawing.PointF ($x + $s * 0.27),   ($y + $s * 0.52)),
        (New-Object System.Drawing.PointF ($x + $s * 0.5),    ($y + $s * 0.12)),
        (New-Object System.Drawing.PointF ($x + $s * 0.73),   ($y + $s * 0.52)),
        (New-Object System.Drawing.PointF ($x + $s),          ($y + $s * 0.22)),
        (New-Object System.Drawing.PointF ($x + $s * 0.86),   ($y + $s * 0.80)),
        (New-Object System.Drawing.PointF ($x + $s * 0.14),   ($y + $s * 0.80))
    )
    $g.FillPolygon($b, $pts)
    $b.Dispose()
}

function Draw-MtSwords($g, [single]$x, [single]$y, [single]$s, $color) {
    $pen = New-Object System.Drawing.Pen $color, ($s * 0.15)
    $pen.StartCap = 'Round'; $pen.EndCap = 'Triangle'
    $g.DrawLine($pen, ($x + $s * 0.15), ($y + $s * 0.85), ($x + $s * 0.85), ($y + $s * 0.15))
    $g.DrawLine($pen, ($x + $s * 0.85), ($y + $s * 0.85), ($x + $s * 0.15), ($y + $s * 0.15))
    $pen.Dispose()
}

function Draw-MtClock($g, [single]$x, [single]$y, [single]$s, $color) {
    $pen = New-Object System.Drawing.Pen $color, ($s * 0.11)
    $g.DrawEllipse($pen, $x, $y, $s, $s)
    $g.DrawLine($pen, ($x + $s * 0.5), ($y + $s * 0.5), ($x + $s * 0.5), ($y + $s * 0.26))
    $g.DrawLine($pen, ($x + $s * 0.5), ($y + $s * 0.5), ($x + $s * 0.72), ($y + $s * 0.58))
    $pen.Dispose()
}

function Draw-MtChartIcon($g, [single]$x, [single]$y, [single]$s, $color) {
    $b = New-Object System.Drawing.SolidBrush $color
    $g.FillRectangle($b, $x, ($y + $s * 0.55), ($s * 0.22), ($s * 0.45))
    $g.FillRectangle($b, ($x + $s * 0.39), ($y + $s * 0.28), ($s * 0.22), ($s * 0.72))
    $g.FillRectangle($b, ($x + $s * 0.78), $y, ($s * 0.22), $s)
    $b.Dispose()
}

function Draw-MtCalendar($g, [single]$x, [single]$y, [single]$s, $color) {
    $pen = New-Object System.Drawing.Pen $color, ($s * 0.1)
    $r = New-MtRoundPath $x ($y + $s * 0.14) $s ($s * 0.86) ($s * 0.14)
    $g.DrawPath($pen, $r); $r.Dispose()
    $g.DrawLine($pen, $x, ($y + $s * 0.42), ($x + $s), ($y + $s * 0.42))
    $g.DrawLine($pen, ($x + $s * 0.28), $y, ($x + $s * 0.28), ($y + $s * 0.24))
    $g.DrawLine($pen, ($x + $s * 0.72), $y, ($x + $s * 0.72), ($y + $s * 0.24))
    $pen.Dispose()
}

function Draw-MtIcon($g, [string]$name, [single]$x, [single]$y, [single]$s, $color) {
    switch ($name) {
        'trophy' { Draw-MtTrophy    $g $x $y $s $color }
        'crown'  { Draw-MtCrown     $g $x $y $s $color }
        'swords' { Draw-MtSwords    $g $x $y $s $color }
        'clock'  { Draw-MtClock     $g $x $y $s $color }
        'chart'  { Draw-MtChartIcon $g $x $y $s $color }
        'cal'    { Draw-MtCalendar  $g $x $y $s $color }
    }
}

function Draw-MtSectionTitle($g, [string]$icon, [string]$text, [single]$x, [single]$y) {
    Draw-MtIcon $g $icon $x ($y + 1) 13 $script:T.Royal
    $f = New-MtFont 8.5 'Bold'
    $b = New-Object System.Drawing.SolidBrush $script:T.Dim
    $g.DrawString($text.ToUpper(), $f, $b, ($x + 21), ($y - 2))
    $f.Dispose(); $b.Dispose()
}

# --------------------------------------------------------------- card de metrica
function New-MtStatCard([string]$label, [string]$value, $color, [string]$icon, [int]$w, [int]$h) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Size = New-Object System.Drawing.Size $w, $h
    $p.BackColor = $script:T.Bg
    $p.Tag = @{ Label = $label; Value = $value; Color = $color; Icon = $icon }
    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = 'AntiAlias'
        $g.TextRenderingHint = 'ClearTypeGridFit'
        $d = $s.Tag
        $path = Draw-MtPanelBg $g $s.Width $s.Height 12
        $g.SetClip($path); $path.Dispose()

        Draw-MtIcon $g $d.Icon 14 13 12 $script:T.Faint

        $fv = New-MtFont 17 'Bold'
        $bv = New-Object System.Drawing.SolidBrush $d.Color
        $g.DrawString($d.Value, $fv, $bv, 12, 27)
        $fv.Dispose(); $bv.Dispose()

        $fl = New-MtFont 8
        $bl = New-Object System.Drawing.SolidBrush $script:T.Faint
        $g.DrawString($d.Label, $fl, $bl, 14, 55)
        $fl.Dispose(); $bl.Dispose()
        $g.ResetClip()
    })
    $p
}

# ------------------------------------------------------------ pilulas de filtro
function New-MtFilterBar($options, [string]$selected, [scriptblock]$onChange, [int]$w, [int]$h) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Size = New-Object System.Drawing.Size $w, $h
    $p.BackColor = $script:T.Bg
    $p.Cursor = 'Hand'
    $p.Tag = @{ Options = @($options); Selected = $selected; OnChange = $onChange; Hot = -1; Rects = @() }
    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = 'AntiAlias'
        $g.TextRenderingHint = 'ClearTypeGridFit'
        $d = $s.Tag
        $f = New-MtFont 9 'Bold'
        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
        $x = 0
        $rects = @()
        foreach ($o in $d.Options) {
            $tw = [Math]::Max(54, [int]($g.MeasureString($o.Label, $f).Width + 28))
            $sel = ($o.Key -eq $d.Selected)
            $hot = ($d.Hot -ge 0 -and $d.Options[$d.Hot].Key -eq $o.Key)
            $path = New-MtRoundPath $x 0 $tw $s.Height 9
            if ($sel) {
                $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                    (New-Object System.Drawing.Point 0, 0),
                    (New-Object System.Drawing.Point 0, $s.Height),
                    $script:T.Royal, $script:T.BorderLit)
                $g.FillPath($grad, $path); $grad.Dispose()
            } else {
                $bgc = if ($hot) { $script:T.Raised } else { $script:T.Surface }
                $b = New-Object System.Drawing.SolidBrush $bgc
                $g.FillPath($b, $path); $b.Dispose()
                $pen = New-Object System.Drawing.Pen $script:T.Border, 1
                $g.DrawPath($pen, $path); $pen.Dispose()
            }
            $tc = if ($sel) { [System.Drawing.Color]::White } elseif ($hot) { $script:T.Text } else { $script:T.Dim }
            $tb = New-Object System.Drawing.SolidBrush $tc
            $g.DrawString($o.Label, $f, $tb, (New-Object System.Drawing.RectangleF $x, 0, $tw, $s.Height), $sf)
            $tb.Dispose(); $path.Dispose()
            $rects += (New-Object System.Drawing.RectangleF $x, 0, $tw, $s.Height)
            $x += $tw + 8
        }
        $d.Rects = $rects
        $f.Dispose()
    })
    $p.Add_MouseMove({
        param($s, $e)
        $d = $s.Tag
        $hot = -1
        $rc = @($d.Rects)
        for ($i = 0; $i -lt $rc.Count; $i++) {
            if ($rc[$i].Contains($e.X, $e.Y)) { $hot = $i; break }
        }
        if ($hot -ne $d.Hot) { $d.Hot = $hot; $s.Invalidate() }
    })
    $p.Add_MouseLeave({ param($s, $e) $s.Tag.Hot = -1; $s.Invalidate() })
    $p.Add_MouseClick({
        param($s, $e)
        $d = $s.Tag
        $rc = @($d.Rects)
        for ($i = 0; $i -lt $rc.Count; $i++) {
            if ($rc[$i].Contains($e.X, $e.Y)) {
                $key = $d.Options[$i].Key
                if ($key -ne $d.Selected) { $d.Selected = $key; $s.Invalidate(); & $d.OnChange $key }
                break
            }
        }
    })
    $p
}

# ------------------------------------------------------------ grafico de linha
# Com crosshair e tooltip: passar o mouse mostra o valor e a data do ponto
# mais proximo. Uma curva sem leitura ponto-a-ponto e quase decorativa.
function New-MtAreaChart($series, [int]$w, [int]$h) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Size = New-Object System.Drawing.Size $w, $h
    $p.BackColor = $script:T.Bg
    $p.Tag = @{ Data = @($series); Hover = -1; Pts = @() }
    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = 'AntiAlias'
        $g.TextRenderingHint = 'ClearTypeGridFit'
        $W = $s.Width; $H = $s.Height
        Draw-MtShadow $g $W $H 14
        $path = Draw-MtPanelBg $g $W $H 14
        $g.SetClip($path); $path.Dispose()

        Draw-MtSectionTitle $g 'trophy' (L 'sec.chart') 18 15

        $st = $s.Tag
        $data = @($st.Data)
        $f = New-MtFont 8
        $bd = New-Object System.Drawing.SolidBrush $script:T.Faint
        if ($data.Count -lt 2) {
            $g.DrawString((L 'empty.points'), $f, $bd, 18, 44)
            $f.Dispose(); $bd.Dispose(); $g.ResetClip(); return
        }

        $padL = 54; $padT = 46; $padB = 22; $padR = 20
        $vals = @($data | ForEach-Object { $_.V })
        $mn = ($vals | Measure-Object -Minimum).Minimum
        $mx = ($vals | Measure-Object -Maximum).Maximum
        if ($mx -eq $mn) { $mx = $mn + 1 }
        $pad = [Math]::Max(1, ($mx - $mn) * 0.18)
        $lo = $mn - $pad; $hi = $mx + $pad
        $plotH = $H - $padT - $padB
        $plotW = $W - $padL - $padR

        $gp = New-Object System.Drawing.Pen $script:T.Border, 1
        $gp.DashStyle = 'Dot'
        for ($i = 0; $i -le 3; $i++) {
            $y = $padT + $plotH * $i / 3
            $g.DrawLine($gp, $padL, $y, ($W - $padR), $y)
            $lbl = [int]($hi - ($hi - $lo) * $i / 3)
            $sz = $g.MeasureString([string]$lbl, $f)
            $g.DrawString([string]$lbl, $f, $bd, ($padL - $sz.Width - 10), ($y - 7))
        }
        $gp.Dispose()

        $n = $data.Count
        $pts = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
        for ($i = 0; $i -lt $n; $i++) {
            $x = $padL + $plotW * $i / [Math]::Max(1, $n - 1)
            $y = $padT + $plotH * (1 - ([double]($data[$i].V - $lo) / ($hi - $lo)))
            $pts.Add((New-Object System.Drawing.PointF $x, $y))
        }
        $st.Pts = $pts   # guardado para o hit-test do mouse

        $fill = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
        $fill.AddRange($pts)
        $fill.Add((New-Object System.Drawing.PointF $pts[$pts.Count - 1].X, ($padT + $plotH)))
        $fill.Add((New-Object System.Drawing.PointF $pts[0].X, ($padT + $plotH)))
        $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            (New-Object System.Drawing.Point 0, $padT),
            (New-Object System.Drawing.Point 0, ($padT + $plotH)),
            [System.Drawing.Color]::FromArgb(96, $script:T.Gold),
            [System.Drawing.Color]::FromArgb(0, $script:T.Gold))
        $g.FillPolygon($lg, $fill.ToArray()); $lg.Dispose()

        $lp = New-Object System.Drawing.Pen $script:T.Gold, 2.4
        $lp.LineJoin = 'Round'
        $g.DrawLines($lp, $pts.ToArray()); $lp.Dispose()

        $last = $pts[$pts.Count - 1]
        $halo = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(70, $script:T.Gold))
        $g.FillEllipse($halo, ($last.X - 8), ($last.Y - 8), 16, 16); $halo.Dispose()
        $dot = New-Object System.Drawing.SolidBrush $script:T.Gold
        $g.FillEllipse($dot, ($last.X - 4.5), ($last.Y - 4.5), 9, 9); $dot.Dispose()
        $wb = New-Object System.Drawing.SolidBrush $script:T.BgDeep
        $g.FillEllipse($wb, ($last.X - 2), ($last.Y - 2), 4, 4); $wb.Dispose()

        # crosshair + tooltip do ponto sob o mouse
        $hv = [int]$st.Hover
        if ($hv -ge 0 -and $hv -lt $n) {
            $hp = $pts[$hv]
            $cp = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(120, $script:T.BorderLit)), 1
            $cp.DashStyle = 'Dash'
            $g.DrawLine($cp, $hp.X, $padT, $hp.X, ($padT + $plotH)); $cp.Dispose()

            $rb = New-Object System.Drawing.SolidBrush $script:T.Bg
            $g.FillEllipse($rb, ($hp.X - 5), ($hp.Y - 5), 10, 10); $rb.Dispose()
            $rp = New-Object System.Drawing.Pen $script:T.Gold, 2
            $g.DrawEllipse($rp, ($hp.X - 5), ($hp.Y - 5), 10, 10); $rp.Dispose()

            $d = $data[$hv]
            $when = [DateTimeOffset]::FromUnixTimeSeconds($d.Ts).LocalDateTime.ToString((L 'fmt.dt'))
            $fb = New-MtFont 9 'Bold'
            $l1 = "$($d.V)"; $l2 = $when
            $w1 = $g.MeasureString($l1, $fb).Width
            $w2 = $g.MeasureString($l2, $f).Width
            $tw = [Math]::Max($w1, $w2) + 20
            $th = 38
            $tx = $hp.X + 12
            if ($tx + $tw -gt $W - 12) { $tx = $hp.X - $tw - 12 }
            $ty = [Math]::Max($padT, [single]($hp.Y - $th - 10))
            $tp = New-MtRoundPath $tx $ty $tw $th 8
            $tb = New-Object System.Drawing.SolidBrush $script:T.Raised
            $g.FillPath($tb, $tp); $tb.Dispose()
            $tpn = New-Object System.Drawing.Pen $script:T.BorderLit, 1
            $g.DrawPath($tpn, $tp); $tpn.Dispose(); $tp.Dispose()
            $gb = New-Object System.Drawing.SolidBrush $script:T.Gold
            $g.DrawString($l1, $fb, $gb, ($tx + 10), ($ty + 5)); $gb.Dispose()
            $g.DrawString($l2, $f, $bd, ($tx + 10), ($ty + 21))
            $fb.Dispose()
        }

        $f.Dispose(); $bd.Dispose()
        $g.ResetClip()
    })
    $p.Add_MouseMove({
        param($s, $e)
        $st = $s.Tag
        $pts = $st.Pts
        if (-not $pts -or @($pts).Count -eq 0) { return }
        $best = -1; $bd = [double]::MaxValue
        for ($i = 0; $i -lt @($pts).Count; $i++) {
            $dx = [Math]::Abs($pts[$i].X - $e.X)
            if ($dx -lt $bd) { $bd = $dx; $best = $i }
        }
        if ($bd -gt 40) { $best = -1 }
        if ($best -ne $st.Hover) { $st.Hover = $best; $s.Invalidate() }
    })
    $p.Add_MouseLeave({ param($s, $e) if ($s.Tag.Hover -ne -1) { $s.Tag.Hover = -1; $s.Invalidate() } })
    $p
}

# --------------------------------------------------------- grafico de colocacoes
# Substitui o antigo "Quanto vale cada colocacao", que mostrava saldos crus e
# exigia que o leitor descobrisse sozinho o que os agrupamentos diziam. Aqui
# a leitura ja vem pronta: quantas vezes voce terminou em cada posicao. A faixa de saldo observada fica no rodape, como
# prova de onde a inferencia sai.
function New-MtPlacementChart($pack, [int]$w, [int]$h) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Size = New-Object System.Drawing.Size $w, $h
    $p.BackColor = $script:T.Bg
    $p.Tag = $pack
    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = 'AntiAlias'
        $g.TextRenderingHint = 'ClearTypeGridFit'
        $W = $s.Width; $H = $s.Height
        Draw-MtShadow $g $W $H 14
        $path = Draw-MtPanelBg $g $W $H 14
        $g.SetClip($path); $path.Dispose()

        Draw-MtSectionTitle $g 'crown' (L 'sec.places') 18 15

        $pack = $s.Tag
        $f    = New-MtFont 8
        $fsm  = New-MtFont 7.5
        $fb   = New-MtFont 9 'Bold'
        $bd   = New-Object System.Drawing.SolidBrush $script:T.Faint
        $bdim = New-Object System.Drawing.SolidBrush $script:T.Dim
        $tot  = [int]$pack.Total

        if ($tot -eq 0) {
            $g.DrawString((L 'empty.matches'), $f, $bd, 18, 46)
            $f.Dispose(); $fsm.Dispose(); $fb.Dispose(); $bd.Dispose(); $bdim.Dispose()
            $g.ResetClip(); return
        }

        $sub = (L 'pl.sub') -f ([string]$pack.Avg), $tot
        if ([int]$pack.Duvida -gt 0) { $sub += (L 'pl.sub.doubt') -f $pack.Duvida }
        $g.DrawString($sub, $fsm, $bd, 18, 34)

        $rows  = @($pack.Rows)
        $mx    = 1
        foreach ($r in $rows) { if ($r.N -gt $mx) { $mx = $r.N } }
        $barX  = 46
        $barW  = $W - 46 - 152
        $y     = 52
        $rh    = [int](($H - 74) / 4)
        $sfr   = New-Object System.Drawing.StringFormat
        $sfr.Alignment = 'Far'

        foreach ($r in $rows) {
            $c = $script:MtPlaceC[$r.Place]
            $lb = New-Object System.Drawing.SolidBrush $c
            $g.DrawString((Get-MtOrd $r.Place), $fb, $lb, 18, ($y + 1))
            $lb.Dispose()

            # trilho: da a escala mesmo quando a barra e curta
            $tr = New-MtRoundPath $barX ($y + 3) $barW 13 6.5
            $tb = New-Object System.Drawing.SolidBrush $script:T.Surface
            $g.FillPath($tb, $tr); $tb.Dispose(); $tr.Dispose()

            $bw = [int]($barW * $r.N / $mx)
            if ($r.N -gt 0 -and $bw -lt 8) { $bw = 8 }
            if ($bw -gt 0) {
                $bp = New-MtRoundPath $barX ($y + 3) $bw 13 6.5
                $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                    (New-Object System.Drawing.Point $barX, 0),
                    (New-Object System.Drawing.Point ($barX + $bw + 1), 0),
                    [System.Drawing.Color]::FromArgb(255, $c),
                    [System.Drawing.Color]::FromArgb(130, $c))
                $g.FillPath($grad, $bp); $grad.Dispose(); $bp.Dispose()
            }

            $vb = New-Object System.Drawing.SolidBrush $c
            $g.DrawString("$($r.N)", $fb, $vb, (New-Object System.Drawing.RectangleF ($W - 148), ($y + 1), 26, 14), $sfr)
            $vb.Dispose()
            $g.DrawString("$($r.Pct)%", $f, $bdim, (New-Object System.Drawing.RectangleF ($W - 118), ($y + 2), 34, 14), $sfr)

            if ($r.Seen) {
                $lo = if ($r.Lo -gt 0) { "+$($r.Lo)" } else { "$($r.Lo)" }
                $hi = if ($r.Hi -gt 0) { "+$($r.Hi)" } else { "$($r.Hi)" }
                $faixa = if ($r.Lo -eq $r.Hi) { $lo } else { "$lo" + [char]0x2026 + "$hi" }
                $g.DrawString($faixa, $fsm, $bd, (New-Object System.Drawing.RectangleF ($W - 78), ($y + 3), 62, 13), $sfr)
            }
            $y += $rh
        }

        $g.DrawString((L 'pl.rule'), $fsm, $bd, 18, ($H - 17))

        $f.Dispose(); $fsm.Dispose(); $fb.Dispose(); $bd.Dispose(); $bdim.Dispose()
        $g.ResetClip()
    })
    $p
}

# ----------------------------------------------------------- grafico de barras
function New-MtBars($data, [int]$w, [int]$h, [string]$chaveTitulo, [string]$icon = 'cal') {
    $p = New-Object System.Windows.Forms.Panel
    $p.Size = New-Object System.Drawing.Size $w, $h
    $p.BackColor = $script:T.Bg
    $p.Tag = @{ Data = @($data); Caption = $chaveTitulo; Icon = $icon }
    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = 'AntiAlias'
        $g.TextRenderingHint = 'ClearTypeGridFit'
        $W = $s.Width; $H = $s.Height
        $path = Draw-MtPanelBg $g $W $H 14
        $g.SetClip($path); $path.Dispose()

        $pack = $s.Tag
        Draw-MtSectionTitle $g $pack.Icon (L $pack.Caption) 18 15

        $data = @($pack.Data)
        $f = New-MtFont 8
        $fb = New-MtFont 8.5 'Bold'
        $bd = New-Object System.Drawing.SolidBrush $script:T.Faint
        if ($data.Count -eq 0) {
            $g.DrawString((L 'empty.matches'), $f, $bd, 18, 44)
            $f.Dispose(); $fb.Dispose(); $bd.Dispose(); $g.ResetClip(); return
        }

        $top = 50; $bottom = $H - 30
        $mid = [int](($top + $bottom) / 2)
        $zp = New-Object System.Drawing.Pen $script:T.Border, 1
        $zp.DashStyle = 'Dot'
        $g.DrawLine($zp, 18, $mid, ($W - 18), $mid); $zp.Dispose()

        $mx = 1
        foreach ($d in $data) { $a = [Math]::Abs($d.Net); if ($a -gt $mx) { $mx = $a } }
        $n = $data.Count
        $slot = ($W - 44) / [Math]::Max($n, 1)
        $bw = [Math]::Max(8, [Math]::Min(34, [int]$slot - 10))
        $x0 = 22 + (($W - 44) - $slot * $n) / 2
        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment = 'Center'
        $maxH = ($mid - $top) - 14

        for ($i = 0; $i -lt $n; $i++) {
            $d = $data[$i]
            $cx = $x0 + $i * $slot + $slot / 2
            $bh = [int]($maxH * [Math]::Abs($d.Net) / $mx)
            if ($bh -lt 3) { $bh = 3 }
            $c = if ($d.Net -ge 0) { $script:T.Up } else { $script:T.Down }
            $y = if ($d.Net -ge 0) { $mid - $bh } else { $mid }
            $bp = New-MtRoundPath ($cx - $bw / 2) $y $bw $bh 5
            $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                (New-Object System.Drawing.Point 0, $y),
                (New-Object System.Drawing.Point 0, ($y + $bh + 1)),
                [System.Drawing.Color]::FromArgb(255, $c),
                [System.Drawing.Color]::FromArgb(110, $c))
            $g.FillPath($grad, $bp); $grad.Dispose(); $bp.Dispose()

            # valor sempre acima do eixo: abaixo colidiria com os rotulos
            $vtxt = if ($d.Net -ge 0) { "+$($d.Net)" } else { "$($d.Net)" }
            $vy = if ($d.Net -ge 0) { $mid - $bh - 15 } else { $mid - 16 }
            $vb = New-Object System.Drawing.SolidBrush $c
            $g.DrawString($vtxt, $fb, $vb, (New-Object System.Drawing.RectangleF ($cx - 40), $vy, 80, 13), $sf)
            $vb.Dispose()

            # 2026-08-27 -> 27/08 ; qualquer outro formato passa inteiro
            $lbl = if ($d.D -match '^\d{4}-(\d{2})-(\d{2})$') { (L 'fmt.daymonth') -f $Matches[2], $Matches[1] } else { $d.D }
            $g.DrawString($lbl, $f, $bd, (New-Object System.Drawing.RectangleF ($cx - 40), ($bottom + 4), 80, 12), $sf)
            $g.DrawString(((L 'ch.games') -f $d.N), $f, $bd, (New-Object System.Drawing.RectangleF ($cx - 40), ($bottom + 15), 80, 12), $sf)
        }
        $f.Dispose(); $fb.Dispose(); $bd.Dispose()
        $g.ResetClip()
    })
    $p
}

# ------------------------------------------------------- lista de partidas
# Rola com a roda do mouse (o Form roteia o evento, ver Invoke-MtScroll) e
# mostra a colocacao inferida de cada jogo. Serve tanto ao bloco baixo da
# visao geral quanto a aba Partidas, que recebe o historico inteiro.
function New-MtMatchList($rows, [int]$w, [int]$h, [string]$chaveTitulo = 'sec.recent') {
    $p = New-Object System.Windows.Forms.Panel
    $p.Size = New-Object System.Drawing.Size $w, $h
    $p.BackColor = $script:T.Bg
    $p.Tag = @{ Rows = @($rows); Scroll = 0; MaxScroll = 0; Titulo = $chaveTitulo }
    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = 'AntiAlias'
        $g.TextRenderingHint = 'ClearTypeGridFit'
        $W = $s.Width; $H = $s.Height
        Draw-MtShadow $g $W $H 14
        $path = Draw-MtPanelBg $g $W $H 14
        $g.SetClip($path); $path.Dispose()

        $st = $s.Tag
        Draw-MtSectionTitle $g 'swords' (L $st.Titulo) 18 15

        $rows = @($st.Rows)
        $f = New-MtFont 9
        $fsm = New-MtFont 8
        $fb = New-MtFont 9.5 'Bold'
        $fdim = New-Object System.Drawing.SolidBrush $script:T.Dim
        $ffaint = New-Object System.Drawing.SolidBrush $script:T.Faint
        $ftext = New-Object System.Drawing.SolidBrush $script:T.Text

        if ($rows.Count -eq 0) {
            $st.MaxScroll = 0
            $g.DrawString((L 'empty.matches'), $f, $ffaint, 18, 46)
            $f.Dispose(); $fsm.Dispose(); $fb.Dispose(); $fdim.Dispose(); $ffaint.Dispose(); $ftext.Dispose()
            $g.ResetClip(); return
        }

        $rh = 32
        $topY = 44
        $rodape = if ($rows.Count -gt 4) { 18 } else { 4 }
        $vis = [Math]::Max(1, [int](($H - $topY - $rodape) / $rh))
        $st.MaxScroll = [Math]::Max(0, $rows.Count - $vis)
        $start = [Math]::Min([int]$st.Scroll, $st.MaxScroll)
        $y = $topY

        for ($i = $start; $i -lt [Math]::Min($rows.Count, $start + $vis); $i++) {
            $r = $rows[$i]
            $zb = New-Object System.Drawing.SolidBrush $(if (($i - $start) % 2 -eq 0) { $script:T.Raised } else { $script:T.Surface })
            $zp = New-MtRoundPath 14 $y ($W - 28) ($rh - 4) 8
            $g.FillPath($zb, $zp); $zb.Dispose(); $zp.Dispose()

            $c = if ($r.Delta -ge 0) { $script:T.Up } else { $script:T.Down }
            $ab = New-Object System.Drawing.SolidBrush $c
            $accent = New-MtRoundPath 14 $y 4 ($rh - 4) 2
            $g.FillPath($ab, $accent); $accent.Dispose()

            Draw-MtIcon $g 'clock' 28 ($y + 8) 12 $script:T.Faint
            $when = [DateTimeOffset]::FromUnixTimeSeconds($r.Ts).LocalDateTime.ToString((L 'fmt.dt'))
            $g.DrawString($when, $f, $fdim, 46, ($y + 6))

            Draw-MtPlacePill $g $r.Place 152 ($y + 5) 40 19 ($r.Certain -ne 1)

            $dtxt = if ($r.Delta -gt 0) { "+$($r.Delta)" } else { "$($r.Delta)" }
            $pw = 56
            $pp = New-MtRoundPath 202 ($y + 5) $pw 19 9
            $pb = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(46, $c))
            $g.FillPath($pb, $pp); $pb.Dispose()
            $ppn = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(120, $c)), 1
            $g.DrawPath($ppn, $pp); $ppn.Dispose()
            $sf = New-Object System.Drawing.StringFormat
            $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
            $g.DrawString($dtxt, $fb, $ab, (New-Object System.Drawing.RectangleF 202, ($y + 5), $pw, 19), $sf)
            $pp.Dispose()

            Draw-MtIcon $g 'trophy' 274 ($y + 7) 13 $script:T.Gold
            $g.DrawString([string]$r.Curr, $f, $ftext, 292, ($y + 6))

            if ($r.Certain -ne 1) {
                $g.DrawString((L 'ml.uncertain'), $fsm, $ffaint, 356, ($y + 8))
            }
            $ab.Dispose()
            $y += $rh
        }

        if ($rows.Count -gt $vis) {
            $de = $start + 1
            $ate = [Math]::Min($rows.Count, $start + $vis)
            $g.DrawString(((L 'ml.range') -f $de, $ate, $rows.Count), $fsm, $ffaint, 18, ($H - 16))
            Draw-MtScrollbar $g ($W - 8) $topY ($vis * $rh) $rows.Count $vis $start
        } elseif ($rows.Count -gt 4) {
            $g.DrawString(((L 'ml.count') -f $rows.Count), $fsm, $ffaint, 18, ($H - 16))
        }

        $f.Dispose(); $fsm.Dispose(); $fb.Dispose(); $fdim.Dispose(); $ffaint.Dispose(); $ftext.Dispose()
        $g.ResetClip()
    })
    $p.Add_MouseWheel({ param($s, $e) Invoke-MtScroll $s $e.Delta })
    $p
}

# Barra de rolagem fina desenhada a mao: o scrollbar nativo nao aceita o tema.
function Draw-MtScrollbar($g, [single]$x, [single]$y, [single]$h, [int]$total, [int]$vis, [int]$start) {
    if ($total -le $vis -or $h -le 0) { return }
    $tr = New-MtRoundPath $x $y 3 $h 1.5
    $tb = New-Object System.Drawing.SolidBrush $script:T.Surface
    $g.FillPath($tb, $tr); $tb.Dispose(); $tr.Dispose()
    $th = [Math]::Max(18, $h * $vis / $total)
    $ty = $y + ($h - $th) * $start / [Math]::Max(1, $total - $vis)
    $kp = New-MtRoundPath $x $ty 3 $th 1.5
    $kb = New-Object System.Drawing.SolidBrush $script:T.BorderLit
    $g.FillPath($kb, $kp); $kb.Dispose(); $kp.Dispose()
}

# ------------------------------------------------------------------- abas
# TabControl nativo nao aceita tema escuro; abas desenhadas a mao com
# sublinhado no item ativo.
function New-MtTabs($labels, [int]$selected, [scriptblock]$onChange, [int]$w, [int]$h) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Size = New-Object System.Drawing.Size $w, $h
    $p.BackColor = $script:T.Bg
    $p.Cursor = 'Hand'
    $p.Tag = @{ Labels = @($labels); Sel = $selected; OnChange = $onChange; Hot = -1; Rects = @() }
    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = 'AntiAlias'
        $g.TextRenderingHint = 'ClearTypeGridFit'
        $d = $s.Tag
        $f = New-MtFont 9.5 'Bold'
        $x = 0
        $rects = @()
        for ($i = 0; $i -lt @($d.Labels).Count; $i++) {
            $lbl = $d.Labels[$i]
            $tw = [int]($g.MeasureString($lbl, $f).Width + 28)
            $sel = ($i -eq $d.Sel)
            $hot = ($i -eq $d.Hot)
            $tc = if ($sel) { $script:T.Text } elseif ($hot) { $script:T.Dim } else { $script:T.Faint }
            $tb = New-Object System.Drawing.SolidBrush $tc
            $sf = New-Object System.Drawing.StringFormat
            $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
            $g.DrawString($lbl, $f, $tb, (New-Object System.Drawing.RectangleF $x, 0, $tw, ($s.Height - 4)), $sf)
            $tb.Dispose()
            if ($sel) {
                $up = New-MtRoundPath ($x + 10) ($s.Height - 4) ($tw - 20) 3 1.5
                $ub = New-Object System.Drawing.SolidBrush $script:T.Royal
                $g.FillPath($ub, $up); $ub.Dispose(); $up.Dispose()
            }
            $rects += (New-Object System.Drawing.RectangleF $x, 0, $tw, $s.Height)
            $x += $tw
        }
        $d.Rects = $rects
        $f.Dispose()
    })
    $p.Add_MouseMove({
        param($s, $e)
        $d = $s.Tag; $hot = -1
        $rc = @($d.Rects)
        for ($i = 0; $i -lt $rc.Count; $i++) { if ($rc[$i].Contains($e.X, $e.Y)) { $hot = $i; break } }
        if ($hot -ne $d.Hot) { $d.Hot = $hot; $s.Invalidate() }
    })
    $p.Add_MouseLeave({ param($s, $e) $s.Tag.Hot = -1; $s.Invalidate() })
    $p.Add_MouseClick({
        param($s, $e)
        $d = $s.Tag
        $rc = @($d.Rects)
        for ($i = 0; $i -lt $rc.Count; $i++) {
            if ($rc[$i].Contains($e.X, $e.Y)) {
                if ($i -ne $d.Sel) { $d.Sel = $i; $s.Invalidate(); & $d.OnChange $i }
                break
            }
        }
    })
    $p
}

# ------------------------------------------------------------ lista de sessoes
# Clicar numa linha abre a sessao e mostra as partidas dela, uma a uma, com a
# colocacao inferida. Sem isso a aba so dizia "voce foi mal ontem a noite" sem
# deixar ver onde foi mal.
function New-MtSessionList($rows, [int]$w, [int]$h) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Size = New-Object System.Drawing.Size $w, $h
    $p.BackColor = $script:T.Bg
    $p.Cursor = 'Hand'
    $p.Tag = @{ Rows = @($rows); Scroll = 0; MaxScroll = 0; Aberta = -1; Hits = @() }
    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = 'AntiAlias'
        $g.TextRenderingHint = 'ClearTypeGridFit'
        $W = $s.Width; $H = $s.Height
        Draw-MtShadow $g $W $H 14
        $path = Draw-MtPanelBg $g $W $H 14
        $g.SetClip($path); $path.Dispose()

        Draw-MtSectionTitle $g 'clock' (L 'sec.sessions') 18 15
        $f    = New-MtFont 9
        $fb   = New-MtFont 10 'Bold'
        $fsm  = New-MtFont 8
        $ftin = New-MtFont 7.5
        $bd   = New-Object System.Drawing.SolidBrush $script:T.Faint
        $bdim = New-Object System.Drawing.SolidBrush $script:T.Dim
        $btx  = New-Object System.Drawing.SolidBrush $script:T.Text

        $st = $s.Tag
        $rows = @($st.Rows)
        if ($rows.Count -eq 0) {
            $st.MaxScroll = 0; $st.Hits = @()
            $g.DrawString((L 'empty.sessions'), $f, $bd, 18, 46)
            $g.DrawString((L 'empty.sessions.2'), $fsm, $bd, 18, 66)
            $f.Dispose(); $fb.Dispose(); $fsm.Dispose(); $ftin.Dispose()
            $bd.Dispose(); $bdim.Dispose(); $btx.Dispose()
            $g.ResetClip(); return
        }

        $g.DrawString((L 'ss.hint'), $ftin, $bd, 190, 17)

        $topY  = 44
        $limY  = $H - 22
        $rh    = 48
        $mrh   = 25
        $start = [Math]::Min([int]$st.Scroll, [Math]::Max(0, $rows.Count - 1))
        $y     = $topY
        $hits  = @()
        $desenhadas = 0

        for ($i = $start; $i -lt $rows.Count; $i++) {
            $r = $rows[$i]
            $aberta = ($i -eq [int]$st.Aberta)
            $nm = if ($aberta) { @($r.Matches).Count } else { 0 }
            $altura = $rh + ($nm * $mrh) + $(if ($aberta) { 8 } else { 0 })
            if ($y + $rh -gt $limY) { break }

            $zb = New-Object System.Drawing.SolidBrush $(if ($aberta) { $script:T.Raised } elseif ($desenhadas % 2 -eq 0) { $script:T.Raised } else { $script:T.Surface })
            $zp = New-MtRoundPath 14 $y ($W - 28) ([Math]::Min($altura - 5, $limY - $y)) 8
            $g.FillPath($zb, $zp); $zb.Dispose(); $zp.Dispose()

            $c = if ($r.Net -ge 0) { $script:T.Up } else { $script:T.Down }
            $ab = New-Object System.Drawing.SolidBrush $c
            $accent = New-MtRoundPath 14 $y 4 ([Math]::Min($altura - 5, $limY - $y)) 2
            $g.FillPath($ab, $accent); $accent.Dispose()

            $ini = [DateTimeOffset]::FromUnixTimeSeconds($r.Start).LocalDateTime
            $fim = [DateTimeOffset]::FromUnixTimeSeconds($r.End).LocalDateTime
            $dur = [int](($r.End - $r.Start) / 60)
            $g.DrawString($ini.ToString((L 'fmt.dt')), $f, $btx, 30, ($y + 7))
            $span = if ($dur -ge 1) { (L 'ss.until') -f $fim.ToString('HH:mm'), $dur } else { L 'ss.short' }
            $g.DrawString($span, $fsm, $bd, 30, ($y + 25))

            $nt = if ($r.Net -ge 0) { "+$($r.Net)" } else { "$($r.Net)" }
            $g.DrawString($nt, $fb, $ab, 168, ($y + 11))

            $qtd = if ($r.N -eq 1) { L 'ss.match.1' } else { (L 'ss.match.n') -f $r.N }
            $g.DrawString($qtd, $f, $bdim, 244, ($y + 7))
            $g.DrawString(((L 'ss.avg') -f "$([math]::Round($r.AvgPlace, 1))"), $fsm, $bd, 244, ($y + 25))

            # barra empilhada com a proporcao de cada colocacao na sessao:
            # diz num relance se a sessao foi ruim por muitos 4o ou por poucos 1o
            $bx = 356.0
            $bw = 220.0
            $tr = New-MtRoundPath $bx ($y + 12) $bw 14 7
            $trb = New-Object System.Drawing.SolidBrush $script:T.Bg
            $g.FillPath($trb, $tr); $trb.Dispose()
            # Save/Restore preserva o clip do painel. Refazer Draw-MtPanelBg aqui
            # repintava o fundo por cima de tudo que ja tinha sido desenhado.
            $estado = $g.Save()
            $g.SetClip($tr, [System.Drawing.Drawing2D.CombineMode]::Intersect)
            $px = $bx
            for ($k = 1; $k -le 4; $k++) {
                $qt = [int]$r.P[$k]
                if ($qt -le 0) { continue }
                $seg = $bw * $qt / $r.N
                $sb2 = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(215, $script:MtPlaceC[$k]))
                $g.FillRectangle($sb2, $px, ($y + 12), $seg, 14); $sb2.Dispose()
                if ($seg -ge 16) {
                    $lbb = New-Object System.Drawing.SolidBrush $script:T.BgDeep
                    $sfc = New-Object System.Drawing.StringFormat
                    $sfc.Alignment = 'Center'; $sfc.LineAlignment = 'Center'
                    $g.DrawString([string]$qt, $ftin, $lbb, (New-Object System.Drawing.RectangleF $px, ($y + 12), $seg, 14), $sfc)
                    $lbb.Dispose()
                }
                $px += $seg
            }
            $g.Restore($estado)
            $trp = New-Object System.Drawing.Pen $script:T.Border, 1
            $g.DrawPath($trp, $tr); $trp.Dispose(); $tr.Dispose()

            Draw-MtIcon $g 'trophy' 604 ($y + 13) 13 $script:T.Gold
            $g.DrawString("$($r.StartTro) " + [char]0x2192 + " $($r.EndTro)", $f, $btx, 622, ($y + 12))

            # seta de expansao
            $chev = New-Object System.Drawing.Pen $(if ($aberta) { $script:T.Text } else { $script:T.Faint }), 2
            $chev.StartCap = 'Round'; $chev.EndCap = 'Round'
            $cxx = $W - 40; $cyy = $y + 20
            if ($aberta) {
                $g.DrawLine($chev, $cxx, ($cyy + 3), ($cxx + 5), ($cyy - 3))
                $g.DrawLine($chev, ($cxx + 5), ($cyy - 3), ($cxx + 10), ($cyy + 3))
            } else {
                $g.DrawLine($chev, $cxx, ($cyy - 3), ($cxx + 5), ($cyy + 3))
                $g.DrawLine($chev, ($cxx + 5), ($cyy + 3), ($cxx + 10), ($cyy - 3))
            }
            $chev.Dispose()

            $hits += [pscustomobject]@{ Idx = $i; Y = $y; H = $rh }
            $y += $rh

            if ($aberta) {
                $sep = New-Object System.Drawing.Pen $script:T.Border, 1
                $g.DrawLine($sep, 30, ($y - 3), ($W - 30), ($y - 3)); $sep.Dispose()
                foreach ($m in @($r.Matches)) {
                    if ($y + $mrh -gt $limY) { break }
                    $mw = [DateTimeOffset]::FromUnixTimeSeconds($m.Ts).LocalDateTime.ToString('HH:mm')
                    $g.DrawString($mw, $fsm, $bd, 44, ($y + 5))
                    Draw-MtPlacePill $g $m.Place 92 ($y + 3) 36 17 ($m.Certain -ne 1)
                    $mc = if ($m.Delta -ge 0) { $script:T.Up } else { $script:T.Down }
                    $mb = New-Object System.Drawing.SolidBrush $mc
                    $mt = if ($m.Delta -gt 0) { "+$($m.Delta)" } else { "$($m.Delta)" }
                    $g.DrawString($mt, $fsm, $mb, 140, ($y + 5)); $mb.Dispose()
                    Draw-MtIcon $g 'trophy' 194 ($y + 5) 11 $script:T.Gold
                    $g.DrawString([string]$m.Curr, $fsm, $bdim, 210, ($y + 5))
                    if ($m.Certain -ne 1) {
                        $g.DrawString((L 'ml.uncertain.s'), $ftin, $bd, 262, ($y + 6))
                    }
                    $y += $mrh
                }
                $y += 8
            }
            $ab.Dispose()
            $desenhadas++
        }

        $st.Hits = $hits
        $st.MaxScroll = [Math]::Max(0, $rows.Count - $desenhadas)
        if ($st.MaxScroll -gt 0) {
            $g.DrawString(((L 'ss.count.scroll') -f $rows.Count), $ftin, $bd, 18, ($H - 16))
            Draw-MtScrollbar $g ($W - 8) $topY ($limY - $topY) $rows.Count $desenhadas $start
        } else {
            $g.DrawString(((L 'ss.count') -f $rows.Count), $ftin, $bd, 18, ($H - 16))
        }

        $f.Dispose(); $fb.Dispose(); $fsm.Dispose(); $ftin.Dispose()
        $bd.Dispose(); $bdim.Dispose(); $btx.Dispose()
        $g.ResetClip()
    })
    $p.Add_MouseWheel({ param($s, $e) Invoke-MtScroll $s $e.Delta 1 })
    $p.Add_MouseClick({
        param($s, $e)
        $st = $s.Tag
        foreach ($hit in @($st.Hits)) {
            if ($e.Y -ge $hit.Y -and $e.Y -lt ($hit.Y + $hit.H)) {
                $st.Aberta = if ([int]$st.Aberta -eq $hit.Idx) { -1 } else { $hit.Idx }
                $s.Invalidate()
                break
            }
        }
    })
    $p
}

# --------------------------------------------------------- desempenho por hora
function New-MtHourChart($hours, [int]$w, [int]$h) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Size = New-Object System.Drawing.Size $w, $h
    $p.BackColor = $script:T.Bg
    $p.Tag = @($hours)
    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = 'AntiAlias'
        $g.TextRenderingHint = 'ClearTypeGridFit'
        $W = $s.Width; $H = $s.Height
        Draw-MtShadow $g $W $H 14
        $path = Draw-MtPanelBg $g $W $H 14
        $g.SetClip($path); $path.Dispose()

        Draw-MtSectionTitle $g 'clock' (L 'sec.hours') 18 15
        $fleg = New-MtFont 7.5
        $bleg = New-Object System.Drawing.SolidBrush $script:T.Faint
        $g.DrawString((L 'ch.hours.legend'), $fleg, $bleg, 250, 17)
        $fleg.Dispose(); $bleg.Dispose()

        $data = @($s.Tag)
        $f = New-MtFont 7.5
        $fb = New-MtFont 8 'Bold'
        $bd = New-Object System.Drawing.SolidBrush $script:T.Faint
        $played = @($data | Where-Object { $_.N -gt 0 })
        if ($played.Count -eq 0) {
            $g.DrawString((L 'empty.hours'), $f, $bd, 18, 46)
            $f.Dispose(); $fb.Dispose(); $bd.Dispose(); $g.ResetClip(); return
        }

        $mxAbs = 1
        foreach ($d in $played) { $a = [Math]::Abs($d.Avg); if ($a -gt $mxAbs) { $mxAbs = $a } }
        $left = 20; $right = $W - 20
        $slot = ($right - $left) / 24
        $top = 50; $bottom = $H - 34
        $mid = [int](($top + $bottom) / 2)
        $zp = New-Object System.Drawing.Pen $script:T.Border, 1
        $zp.DashStyle = 'Dot'
        $g.DrawLine($zp, $left, $mid, $right, $mid); $zp.Dispose()
        $maxH = ($mid - $top) - 16

        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment = 'Center'
        for ($i = 0; $i -lt 24; $i++) {
            $d = $data[$i]
            $cx = $left + $i * $slot + $slot / 2
            if ($d.N -gt 0) {
                $bh = [int]($maxH * [Math]::Abs($d.Avg) / $mxAbs)
                if ($bh -lt 3) { $bh = 3 }
                $c = if ($d.Avg -ge 0) { $script:T.Up } else { $script:T.Down }
                $y = if ($d.Avg -ge 0) { $mid - $bh } else { $mid }
                $bw = [Math]::Max(6, $slot - 5)
                $bp = New-MtRoundPath ($cx - $bw / 2) $y $bw $bh 3
                $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                    (New-Object System.Drawing.Point 0, $y),
                    (New-Object System.Drawing.Point 0, ($y + $bh + 1)),
                    [System.Drawing.Color]::FromArgb(255, $c),
                    [System.Drawing.Color]::FromArgb(110, $c))
                $g.FillPath($grad, $bp); $grad.Dispose(); $bp.Dispose()
                # a contagem fica colada na ponta da barra. No eixo, a 120px de
                # distancia, ninguem ligava o numero a barra certa.
                $nb = New-Object System.Drawing.SolidBrush $script:T.Dim
                $ny = if ($d.Avg -ge 0) { $y - 13 } else { $y + $bh + 2 }
                $g.DrawString([string]$d.N, $f, $nb, (New-Object System.Drawing.RectangleF ($cx - 20), $ny, 40, 11), $sf)
                $nb.Dispose()
            } else {
                # hora sem partida: marca discreta na linha de base
                $eb = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(70, $script:T.Faint))
                $g.FillRectangle($eb, ($cx - 1.5), ($mid - 1), 3, 2); $eb.Dispose()
            }
            if ($i % 3 -eq 0) {
                $g.DrawString(("{0:00}h" -f $i), $f, $bd, (New-Object System.Drawing.RectangleF ($cx - 20), ($bottom + 1), 40, 11), $sf)
            }
        }
        $f.Dispose(); $fb.Dispose(); $bd.Dispose()
        $g.ResetClip()
    })
    $p
}

# ---------------------------------------------------- desempenho por dia da semana
function New-MtWeekdayChart($days, [int]$w, [int]$h) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Size = New-Object System.Drawing.Size $w, $h
    $p.BackColor = $script:T.Bg
    $p.Tag = $days
    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = 'AntiAlias'
        $g.TextRenderingHint = 'ClearTypeGridFit'
        $W = $s.Width; $H = $s.Height
        Draw-MtShadow $g $W $H 14
        $path = Draw-MtPanelBg $g $W $H 14
        $g.SetClip($path); $path.Dispose()

        Draw-MtSectionTitle $g 'cal' (L 'sec.weekdays') 18 15
        $fleg = New-MtFont 7.5
        $bleg = New-Object System.Drawing.SolidBrush $script:T.Faint
        $g.DrawString((L 'ch.week.legend'), $fleg, $bleg, 258, 17)
        $fleg.Dispose(); $bleg.Dispose()

        $data = $s.Tag
        $f = New-MtFont 8.5
        $fb = New-MtFont 9 'Bold'
        $bd = New-Object System.Drawing.SolidBrush $script:T.Faint
        $played = @($data | Where-Object { $_.N -gt 0 })
        if ($played.Count -eq 0) {
            $g.DrawString((L 'empty.weekdays'), $f, $bd, 18, 46)
            $f.Dispose(); $fb.Dispose(); $bd.Dispose(); $g.ResetClip(); return
        }

        $mxAbs = 1
        foreach ($d in $played) { $a = [Math]::Abs($d.Avg); if ($a -gt $mxAbs) { $mxAbs = $a } }
        $left = 24; $right = $W - 24
        $slot = ($right - $left) / 7
        $top = 52; $bottom = $H - 40
        $mid = [int](($top + $bottom) / 2)
        $zp = New-Object System.Drawing.Pen $script:T.Border, 1
        $zp.DashStyle = 'Dot'
        $g.DrawLine($zp, $left, $mid, $right, $mid); $zp.Dispose()
        $maxH = ($mid - $top) - 8

        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment = 'Center'
        for ($i = 0; $i -lt 7; $i++) {
            $d = $data[$i]
            $cx = $left + $i * $slot + $slot / 2
            $bw = [Math]::Min(56, $slot - 18)
            if ($d.N -gt 0) {
                $bh = [int]($maxH * [Math]::Abs($d.Avg) / $mxAbs)
                if ($bh -lt 4) { $bh = 4 }
                $c = if ($d.Avg -ge 0) { $script:T.Up } else { $script:T.Down }
                $y = if ($d.Avg -ge 0) { $mid - $bh } else { $mid }
                $bp = New-MtRoundPath ($cx - $bw / 2) $y $bw $bh 5
                $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                    (New-Object System.Drawing.Point 0, $y),
                    (New-Object System.Drawing.Point 0, ($y + $bh + 1)),
                    [System.Drawing.Color]::FromArgb(255, $c),
                    [System.Drawing.Color]::FromArgb(110, $c))
                $g.FillPath($grad, $bp); $grad.Dispose(); $bp.Dispose()
                $vb = New-Object System.Drawing.SolidBrush $c
                $vt = if ($d.Avg -ge 0) { "+$($d.Avg)" } else { "$($d.Avg)" }
                $vy = if ($d.Avg -ge 0) { $mid - $bh - 16 } else { $mid - 17 }
                $g.DrawString($vt, $fb, $vb, (New-Object System.Drawing.RectangleF ($cx - 40), $vy, 80, 14), $sf)
                $vb.Dispose()
                $nb = New-Object System.Drawing.SolidBrush $script:T.Dim
                $g.DrawString(((L 'ch.games') -f $d.N), $f, $nb, (New-Object System.Drawing.RectangleF ($cx - 40), ($bottom + 16), 80, 13), $sf)
                $nb.Dispose()
            } else {
                $eb = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(60, $script:T.Faint))
                $g.FillRectangle($eb, ($cx - $bw / 2), ($mid - 2), $bw, 4); $eb.Dispose()
            }
            $lb = New-Object System.Drawing.SolidBrush $(if ($d.N -gt 0) { $script:T.Dim } else { $script:T.Faint })
            $g.DrawString($d.D, $fb, $lb, (New-Object System.Drawing.RectangleF ($cx - 40), ($bottom + 2), 80, 14), $sf)
            $lb.Dispose()
        }
        $f.Dispose(); $fb.Dispose(); $bd.Dispose()
        $g.ResetClip()
    })
    $p
}

# ------------------------------------------------------ barra de titulo propria
function Add-MtTitleBar($form, [string]$title) {
    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = 'Top'
    $bar.Height = 48
    $bar.BackColor = $script:T.BgDeep
    $bar.Tag = $title
    $bar.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = 'AntiAlias'
        $g.TextRenderingHint = 'ClearTypeGridFit'
        $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            (New-Object System.Drawing.Point 0, 0),
            (New-Object System.Drawing.Point 0, $s.Height),
            $script:T.Surface, $script:T.BgDeep)
        $g.FillRectangle($grad, 0, 0, $s.Width, $s.Height); $grad.Dispose()
        $pen = New-Object System.Drawing.Pen $script:T.Border, 1
        $g.DrawLine($pen, 0, ($s.Height - 1), $s.Width, ($s.Height - 1)); $pen.Dispose()
        Draw-MtCrown $g 18 16 16 $script:T.Gold
        $f = New-MtFont 10 'Bold'
        $b = New-Object System.Drawing.SolidBrush $script:T.Text
        $g.DrawString($s.Tag, $f, $b, 42, 14)
        $f.Dispose(); $b.Dispose()
    })
    $bar.Add_MouseDown({ param($s, $e) if ($e.Button -eq 'Left') { [MtWin]::Drag($s.FindForm().Handle) } })
    # so apos entrar no form a largura real fica conhecida
    $form.Controls.Add($bar)

    foreach ($spec in @(@{ T = 'X'; X = -46; Act = 'close' }, @{ T = '-'; X = -84; Act = 'min' })) {
        $b = New-Object System.Windows.Forms.Label
        $b.Text = $spec.T
        $b.Font = New-MtFont 11
        $b.ForeColor = $script:T.Dim
        $b.BackColor = $script:T.Surface
        $b.TextAlign = 'MiddleCenter'
        $b.Size = New-Object System.Drawing.Size 34, 26
        $b.Anchor = 'Top,Right'
        $b.Tag = $spec.Act
        $b.Cursor = 'Hand'
        $b.Add_MouseEnter({ param($s, $e)
            $s.BackColor = if ($s.Tag -eq 'close') { $script:T.Down } else { $script:T.Raised }
            $s.ForeColor = [System.Drawing.Color]::White })
        $b.Add_MouseLeave({ param($s, $e)
            $s.BackColor = $script:T.Surface; $s.ForeColor = $script:T.Dim })
        $b.Add_Click({ param($s, $e)
            $frm = $s.FindForm()
            if ($s.Tag -eq 'close') { $frm.Hide() } else { $frm.WindowState = 'Minimized' } })
        $bar.Controls.Add($b)
        $b.Left = $bar.Width + $spec.X
        $b.Top = 11
        $b.BringToFront()
    }
    $bar
}
