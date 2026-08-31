# MtI18n.ps1 - interface strings, English and Portuguese.
# L() returns the current language and falls back to English, so no text can
# vanish from the screen. Strings with numbers use -f: (L 'key') -f $value.

$script:MtLang = 'en'

$script:MtStrings = @{

    pt = @{
        'card.matches'      = 'Partidas'
        'card.net'          = 'Saldo'
        'card.avg'          = 'Média por jogo'
        'card.place'        = 'Posição média'

        'hdr.record.at'     = 'Recorde da temporada: {0} — você está nele'
        'hdr.record.below'  = 'Recorde da temporada: {0}   ({1} para reencostar)'
        'hdr.streaks'       = 'Maior sequência: {0} vitórias   ·   {1} quedas'
        'hdr.streak.up'     = '{0} vitórias seguidas'
        'hdr.streak.down'   = '{0} quedas seguidas'

        'per.24h'           = '24h'
        'per.7d'            = '7 dias'
        'per.30d'           = '30 dias'
        'per.all'           = 'Tudo'

        'tab.overview'      = 'Visão geral'
        'tab.matches'       = 'Partidas'
        'tab.sessions'      = 'Sessões'
        'tab.hours'         = 'Horários'

        'sec.chart'         = 'Troféus ao longo do tempo'
        'sec.daily'         = 'Saldo por dia'
        'sec.places'        = 'Colocações'
        'sec.recent'        = 'Partidas recentes'
        'sec.history'       = 'Histórico de partidas'
        'sec.sessions'      = 'Sessões de jogo'
        'sec.hours'         = 'Desempenho por hora do dia'
        'sec.weekdays'      = 'Desempenho por dia da semana'

        'empty.matches'     = 'Nenhuma partida neste período'
        'empty.points'      = 'Ainda não há pontos suficientes neste período'
        'empty.sessions'    = 'Nenhuma sessão registrada ainda'
        'empty.sessions.2'  = 'Partidas separadas por menos de 30 min contam como uma sessão.'
        'empty.hours'       = 'Ainda sem partidas para cruzar com o horário'
        'empty.weekdays'    = 'Ainda sem partidas para cruzar com o dia da semana'

        'pl.sub'            = 'colocação média {0}   ·   {1} partidas'
        'pl.sub.doubt'      = '   ·   {0} com leitura espaçada'
        'pl.rule'           = 'posição inferida pelo saldo:  1º >= +18   ·   2º +1 a +17   ·   3º -1 a -16   ·   4º <= -17'

        'ml.uncertain'      = 'leitura espaçada — pode somar mais de uma partida, colocação incerta'
        'ml.uncertain.s'    = 'leitura espaçada — colocação incerta'
        'ml.range'          = '{0}–{1} de {2} partidas   ·   role com a roda do mouse'
        'ml.count'          = '{0} partidas'

        'ss.hint'           = 'clique numa sessão para ver as partidas dela'
        'ss.until'          = 'até {0}  ·  {1} min'
        'ss.short'          = 'sessão curta'
        'ss.match.1'        = '1 partida'
        'ss.match.n'        = '{0} partidas'
        'ss.avg'            = 'média {0}'
        'ss.count'          = '{0} sessões'
        'ss.count.scroll'   = '{0} sessões  ·  role com a roda do mouse'

        'ch.hours.legend'   = 'altura = saldo médio por partida   ·   número = partidas jogadas'
        'ch.week.legend'    = 'altura = saldo médio por partida'
        'ch.games'          = '{0} jogos'

        'fmt.dt'            = 'dd/MM  HH:mm'
        'fmt.daymonth'      = '{0}/{1}'

        'wd.0' = 'Dom'; 'wd.1' = 'Seg'; 'wd.2' = 'Ter'; 'wd.3' = 'Qua'
        'wd.4' = 'Qui'; 'wd.5' = 'Sex'; 'wd.6' = 'Sáb'

        'ft.text'           = 'Última leitura às {0}   ·   lendo a cada {1}s   ·   {2} partidas registradas'
        'ft.stopped'        = 'COLETA PARADA há {0} min   ·   '

        'menu.open'         = 'Abrir painel'
        'menu.now'          = 'Ler agora'
        'menu.export'       = 'Exportar CSV'
        'menu.pause'        = 'Pausar coleta'
        'menu.resume'       = 'Retomar coleta'
        'menu.lang'         = 'Switch to English'
        'menu.tray'         = 'Minimizar para a bandeja'
        'menu.quit'         = 'Sair'

        'tray.tip'          = '{0} troféus - {1}'
        'toast.match'       = '{0} lugar · {1} troféus → {2} · {3}'
        'toast.arena'       = 'Merge Tactics — nova arena'
        'toast.arena.body'  = '{0} · {1} troféus'
        'toast.export.ok'   = '{0} partidas exportadas para merge-tactics.csv na área de trabalho'
        'toast.export.err'  = 'Não foi possível exportar o CSV'
        'alert.auth'        = 'Merge Tactics parou de coletar'
        'alert.auth.body'   = 'Token recusado (403). O token está travado num IP e o seu provavelmente mudou. Gere outro em developer.clashroyale.com'
        'alert.off'         = 'Merge Tactics sem coletar há mais de 30 min'
        'alert.off.body'    = '{0} falhas seguidas. Partidas jogadas agora serão agrupadas numa leitura só.'
        'alert.noseason'    = 'Merge Tactics não encontrado'
        'alert.noseason.b'  = 'A API responde, mas o campo progress não tem nenhuma chave conhecida do modo. A Supercell pode ter renomeado.'
    }

    en = @{
        'card.matches'      = 'Matches'
        'card.net'          = 'Net'
        'card.avg'          = 'Avg per game'
        'card.place'        = 'Avg place'

        'hdr.record.at'     = "Season best: {0} — you're on it"
        'hdr.record.below'  = 'Season best: {0}   ({1} to catch up)'
        'hdr.streaks'       = 'Longest streak: {0} wins   ·   {1} losses'
        'hdr.streak.up'     = '{0} wins in a row'
        'hdr.streak.down'   = '{0} drops in a row'

        'per.24h'           = '24h'
        'per.7d'            = '7 days'
        'per.30d'           = '30 days'
        'per.all'           = 'All'

        'tab.overview'      = 'Overview'
        'tab.matches'       = 'Matches'
        'tab.sessions'      = 'Sessions'
        'tab.hours'         = 'Hours'

        'sec.chart'         = 'Trophies over time'
        'sec.daily'         = 'Net per day'
        'sec.places'        = 'Placements'
        'sec.recent'        = 'Recent matches'
        'sec.history'       = 'Match history'
        'sec.sessions'      = 'Play sessions'
        'sec.hours'         = 'Performance by hour of day'
        'sec.weekdays'      = 'Performance by weekday'

        'empty.matches'     = 'No matches in this period'
        'empty.points'      = 'Not enough points in this period yet'
        'empty.sessions'    = 'No sessions recorded yet'
        'empty.sessions.2'  = 'Matches less than 30 min apart count as one session.'
        'empty.hours'       = 'Not enough matches to cross with time of day'
        'empty.weekdays'    = 'Not enough matches to cross with weekday'

        'pl.sub'            = 'avg place {0}   ·   {1} matches'
        'pl.sub.doubt'      = '   ·   {0} from a spaced reading'
        'pl.rule'           = 'place inferred from net:  1st >= +18   ·   2nd +1 to +17   ·   3rd -1 to -16   ·   4th <= -17'

        'ml.uncertain'      = 'spaced reading — may cover more than one match, place uncertain'
        'ml.uncertain.s'    = 'spaced reading — place uncertain'
        'ml.range'          = '{0}–{1} of {2} matches   ·   scroll with the mouse wheel'
        'ml.count'          = '{0} matches'

        'ss.hint'           = 'click a session to see its matches'
        'ss.until'          = 'until {0}  ·  {1} min'
        'ss.short'          = 'short session'
        'ss.match.1'        = '1 match'
        'ss.match.n'        = '{0} matches'
        'ss.avg'            = 'avg {0}'
        'ss.count'          = '{0} sessions'
        'ss.count.scroll'   = '{0} sessions  ·  scroll with the mouse wheel'

        'ch.hours.legend'   = 'height = average net per match   ·   number = matches played'
        'ch.week.legend'    = 'height = average net per match'
        'ch.games'          = '{0} games'

        'fmt.dt'            = 'MM/dd  HH:mm'
        'fmt.daymonth'      = '{1}/{0}'

        'wd.0' = 'Sun'; 'wd.1' = 'Mon'; 'wd.2' = 'Tue'; 'wd.3' = 'Wed'
        'wd.4' = 'Thu'; 'wd.5' = 'Fri'; 'wd.6' = 'Sat'

        'ft.text'           = 'Last read at {0}   ·   reading every {1}s   ·   {2} matches recorded'
        'ft.stopped'        = 'COLLECTION STOPPED for {0} min   ·   '

        'menu.open'         = 'Open panel'
        'menu.now'          = 'Read now'
        'menu.export'       = 'Export CSV'
        'menu.pause'        = 'Pause collection'
        'menu.resume'       = 'Resume collection'
        'menu.lang'         = 'Mudar para português'
        'menu.tray'         = 'Minimize to the tray'
        'menu.quit'         = 'Quit'

        'tray.tip'          = '{0} trophies - {1}'
        'toast.match'       = '{0} place · {1} trophies → {2} · {3}'
        'toast.arena'       = 'Merge Tactics — new arena'
        'toast.arena.body'  = '{0} · {1} trophies'
        'toast.export.ok'   = '{0} matches exported to merge-tactics.csv on the desktop'
        'toast.export.err'  = 'Could not export the CSV'
        'alert.auth'        = 'Merge Tactics stopped collecting'
        'alert.auth.body'   = 'Token rejected (403). The token is locked to an IP and yours probably changed. Generate a new one at developer.clashroyale.com'
        'alert.off'         = 'Merge Tactics has not collected for over 30 min'
        'alert.off.body'    = '{0} failures in a row. Matches played now will be lumped into a single reading.'
        'alert.noseason'    = 'Merge Tactics not found'
        'alert.noseason.b'  = 'The API responds, but the progress field has no known key for the mode. Supercell may have renamed it.'
    }
}

# Current-language text, falling back to English.
function L([string]$k) {
    $t = $script:MtStrings[$script:MtLang]
    if ($t -and $t.ContainsKey($k)) { return $t[$k] }
    $en = $script:MtStrings['en']
    if ($en.ContainsKey($k)) { return $en[$k] }
    $k
}

# Placement ordinal: 1st..4th in English, 1o..4o in Portuguese.
function Get-MtOrd([int]$n) {
    if ($script:MtLang -eq 'en') {
        switch ($n) { 1 { '1st' } 2 { '2nd' } 3 { '3rd' } default { "${n}th" } }
    } else {
        "$n" + [char]0x00BA
    }
}

# Initial language follows Windows, defaulting to English.
function Get-MtSystemLang {
    if ([System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'pt') { 'pt' } else { 'en' }
}
