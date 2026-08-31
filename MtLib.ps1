# MtLib.ps1 - data layer: SQLite, network, alerts, log.
# Uses the winsqlite3.dll that ships with Windows, via P/Invoke. No dependencies.

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class MtSq {
  const string DLL = "winsqlite3.dll";
  [DllImport(DLL, EntryPoint="sqlite3_open16", CharSet=CharSet.Unicode)]
  static extern int Open(string f, out IntPtr db);
  [DllImport(DLL, EntryPoint="sqlite3_close")] static extern int Close(IntPtr db);
  [DllImport(DLL, EntryPoint="sqlite3_prepare16_v2", CharSet=CharSet.Unicode)]
  static extern int Prepare(IntPtr db, string sql, int n, out IntPtr st, IntPtr tail);
  [DllImport(DLL, EntryPoint="sqlite3_step")] static extern int Step(IntPtr st);
  [DllImport(DLL, EntryPoint="sqlite3_finalize")] static extern int Fin(IntPtr st);
  [DllImport(DLL, EntryPoint="sqlite3_column_count")] static extern int ColCount(IntPtr st);
  [DllImport(DLL, EntryPoint="sqlite3_column_name16", CharSet=CharSet.Unicode)]
  static extern IntPtr ColName(IntPtr st, int i);
  [DllImport(DLL, EntryPoint="sqlite3_column_text16", CharSet=CharSet.Unicode)]
  static extern IntPtr ColText(IntPtr st, int i);
  [DllImport(DLL, EntryPoint="sqlite3_errmsg16", CharSet=CharSet.Unicode)]
  static extern IntPtr ErrMsg(IntPtr db);
  [DllImport(DLL, EntryPoint="sqlite3_busy_timeout")] static extern int BusyTimeout(IntPtr db, int ms);

  static string Err(IntPtr db){ IntPtr p = ErrMsg(db); return p==IntPtr.Zero ? "?" : Marshal.PtrToStringUni(p); }

  public static IntPtr OpenDb(string f){
    IntPtr d;
    if(Open(f, out d)!=0) throw new Exception("sqlite open falhou: " + f);
    BusyTimeout(d, 5000);
    return d;
  }
  public static void CloseDb(IntPtr d){ Close(d); }

  public static void Exec(IntPtr db, string sql){
    IntPtr st;
    if(Prepare(db, sql, -1, out st, IntPtr.Zero)!=0) throw new Exception("sqlite: " + Err(db) + " | " + sql);
    while(Step(st)==100){}
    Fin(st);
  }
  public static List<Dictionary<string,string>> Query(IntPtr db, string sql){
    var rows = new List<Dictionary<string,string>>();
    IntPtr st;
    if(Prepare(db, sql, -1, out st, IntPtr.Zero)!=0) throw new Exception("sqlite: " + Err(db) + " | " + sql);
    int n = ColCount(st);
    while(Step(st)==100){
      var r = new Dictionary<string,string>();
      for(int i=0;i<n;i++){
        string k = Marshal.PtrToStringUni(ColName(st,i));
        IntPtr v = ColText(st,i);
        r[k] = (v==IntPtr.Zero) ? null : Marshal.PtrToStringUni(v);
      }
      rows.Add(r);
    }
    Fin(st);
    return rows;
  }
}
"@ -ErrorAction SilentlyContinue

$script:MtRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $script:MtRoot) { $script:MtRoot = "$env:USERPROFILE\mt-tracker" }

function Get-MtPaths {
    @{
        Root  = $script:MtRoot
        Db    = Join-Path $script:MtRoot 'mt.db'
        Token = Join-Path $script:MtRoot 'token.txt'
        Tag   = Join-Path $script:MtRoot 'tag.txt'
        Log   = Join-Path $script:MtRoot 'tracker.log'
        Alert = Join-Path $script:MtRoot 'ALERTA.txt'
    }
}

# Escapes single quotes for safe SQL interpolation.
function ConvertTo-SqlText([string]$s) {
    if ($null -eq $s) { return 'NULL' }
    "'" + ($s -replace "'", "''") + "'"
}

$script:MtSchema = @"
CREATE TABLE IF NOT EXISTS seasons (id INTEGER PRIMARY KEY, key TEXT UNIQUE NOT NULL);
CREATE TABLE IF NOT EXISTS matches (
    ts INTEGER PRIMARY KEY, season_id INTEGER NOT NULL, curr INTEGER NOT NULL,
    delta INTEGER NOT NULL, gap_s INTEGER NOT NULL, certain INTEGER NOT NULL,
    sample_s INTEGER NOT NULL DEFAULT 60);
CREATE TABLE IF NOT EXISTS snapshots (
    ts INTEGER PRIMARY KEY, season_id INTEGER NOT NULL, trophies INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS state (k TEXT PRIMARY KEY, v TEXT);
CREATE TABLE IF NOT EXISTS events (ts INTEGER, kind TEXT, detail TEXT);
CREATE INDEX IF NOT EXISTS idx_matches_season ON matches(season_id);
CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);
"@

function Open-MtDb {
    $p = Get-MtPaths
    $db = [MtSq]::OpenDb($p.Db)
    foreach ($stmt in ($script:MtSchema -split ';')) {
        $s = $stmt.Trim()
        if ($s) { [MtSq]::Exec($db, $s) }
    }
    $db
}

function Invoke-MtExec($db, [string]$sql)  { [MtSq]::Exec($db, $sql) }

# Always returns an array, empty or single-element included.
# Do NOT wrap the call in @(): that re-wraps the array and foreach then iterates
# the list instead of the rows. Assign and use directly.
function Invoke-MtQuery($db, [string]$sql) {
    $list = [MtSq]::Query($db, $sql)
    # The comma stops PowerShell from unrolling the array: without it an empty
    # result would reach the caller as $null.
    if ($list.Count -eq 0) { return , @() }
    , $list.ToArray()
}

function Get-MtState($db, [string]$k) {
    $r = Invoke-MtQuery $db "SELECT v FROM state WHERE k=$(ConvertTo-SqlText $k)"
    if ($r.Count) { $r[0]['v'] } else { $null }
}
function Set-MtState($db, [string]$k, $v) {
    Invoke-MtExec $db "INSERT OR REPLACE INTO state (k,v) VALUES ($(ConvertTo-SqlText $k),$(ConvertTo-SqlText ([string]$v)))"
}
function Get-MtSeasonId($db, [string]$key) {
    $q = ConvertTo-SqlText $key
    Invoke-MtExec $db "INSERT OR IGNORE INTO seasons (key) VALUES ($q)"
    [int](Invoke-MtQuery $db "SELECT id FROM seasons WHERE key=$q")[0]['id']
}

function Write-MtEvent($db, [string]$kind, [string]$detail, [int]$throttle = 300) {
    $now = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $k = ConvertTo-SqlText $kind
    if ($throttle -gt 0) {
        $last = Invoke-MtQuery $db "SELECT rowid, ts, detail FROM events WHERE kind=$k ORDER BY ts DESC LIMIT 1"
        if ($last.Count -and ($now - [int]$last[0]['ts']) -lt $throttle) {
            $d = $last[0]['detail']
            $base = ($d -split '  \(x')[0]
            $n = 2
            if ($d -match '\(x(\d+)\)$') { $n = [int]$Matches[1] + 1 }
            $nd = ConvertTo-SqlText "$base  (x$n)"
            Invoke-MtExec $db "UPDATE events SET detail=$nd WHERE rowid=$($last[0]['rowid'])"
            return
        }
    }
    Invoke-MtExec $db "INSERT INTO events (ts,kind,detail) VALUES ($now,$k,$(ConvertTo-SqlText $detail))"
    $cut = $now - (30 * 86400)
    Invoke-MtExec $db "DELETE FROM events WHERE ts < $cut AND rowid NOT IN (SELECT rowid FROM events ORDER BY ts DESC LIMIT 500)"
}

function Show-MtToast([string]$Title, [string]$Body) {
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
        $t = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
                [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $n = $t.GetElementsByTagName('text')
        [void]$n.Item(0).AppendChild($t.CreateTextNode($Title))
        [void]$n.Item(1).AppendChild($t.CreateTextNode($Body))
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Merge Tactics').Show(
            [Windows.UI.Notifications.ToastNotification]::new($t))
    } catch { }
}

function Write-MtLog([string]$msg) {
    $p = Get-MtPaths
    $line = "[{0}] {1}" -f (Get-Date -Format 'dd/MM HH:mm:ss'), $msg
    try {
        Add-Content -Path $p.Log -Value $line -Encoding UTF8
        # keep the log small
        $fi = Get-Item $p.Log -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -gt 512KB) {
            (Get-Content $p.Log -Tail 500) | Set-Content $p.Log -Encoding UTF8
        }
    } catch { }
}

# ------------------------------------------------------------------- network
# Not Invoke-RestMethod: ConvertFrom-Json on PowerShell 5.1 rejects the empty
# key ("") the API returns inside `progress`, and it does not negotiate gzip
# (45 KB per read instead of 9 KB).
Add-Type -AssemblyName System.Web.Extensions -ErrorAction SilentlyContinue

function Invoke-MtApi {
    param([string]$Url, [string]$Token, [int]$TimeoutSec = 20)

    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = 'GET'
    $req.Timeout = $TimeoutSec * 1000
    $req.ReadWriteTimeout = $TimeoutSec * 1000
    $req.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor
                                  [System.Net.DecompressionMethods]::Deflate
    $req.Headers.Add('Authorization', "Bearer $Token")
    $req.Accept = 'application/json'
    $req.UserAgent = 'mt-tracker-win/1.0'
    $req.KeepAlive = $true

    try {
        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader $resp.GetResponseStream()
        $body = $sr.ReadToEnd()
        $sr.Close(); $resp.Close()
        $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $js.MaxJsonLength = [int]::MaxValue
        return @{ Status = 200; Data = $js.DeserializeObject($body) }
    } catch [System.Net.WebException] {
        $code = 0
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        return @{ Status = $code; Data = $null; Error = $_.Exception.Message }
    } catch {
        return @{ Status = 0; Data = $null; Error = $_.Exception.Message }
    }
}
