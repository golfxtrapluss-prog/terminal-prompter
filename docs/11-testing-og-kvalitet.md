# 11 – Testing og kvalitet

## Testpyramide

| Nivå | Hva | Verktøy | Kjøres |
|---|---|---|---|
| Enhet | codec, ringbuffer, keymap-encoder, config-parsing, argon2/TOTP (RFC-vektorer), stinormalisering | `package:test` | Hver commit |
| Komponent | PTY: start skall, skriv `echo hi`, les output, resize → `stty size`, Ctrl-C avbryter `sleep 100`, exit-kode | `dart test` på Linux | Hver commit |
| Integrasjon | Ekte agent på tilfeldig port + Dart-testklient (`tp_protocol` + `dart:io WebSocket`): login, attach, input, brudd, gjenopptak, SSE-fallback | `dart test --tags integration` | Hver commit |
| Nettverk | Integrasjonstestene gjennom `tp_netsim` med profilene geo/leo/hostile | `--tags netsim` | Hver PR + nattlig |
| Nettleser | Klientlogikk (tilstandsmaskin, prompter-kø) | `dart test -p chrome` | Hver PR |
| Ende-til-ende | Playwright mot ekte agent i Docker: logg inn, kjør kommando, vim, filopplasting | Playwright (eneste ikke-Dart-verktøy, kun test) | Før release |
| Manuell | Fra ekte skipsnett / Starlink / mobil-hotspot med `tc netem` | Sjekkliste | Før release |

## Kritiske testscenarier (må finnes fra M3)

1. **Gjenopptak uten tap:** start `seq 1 100000`, kutt forbindelsen midt i, koble til igjen → klient har alle linjer nøyaktig én gang.
2. **Idempotent input:** send `echo X >> f` med samme `client_msg_id` to ganger (simulert resend) → `f` har én linje.
3. **Truncation:** generer > scrollback output mens frakoblet → `attached.truncated` sendes, klient viser markør.
4. **Treg klient:** klient som ikke leser → agentens minne vokser ikke over grensen; klient kobles fra; gjenopptak fungerer.
5. **WS blokkert:** netsim avviser Upgrade → klient faller til SSE innen 10 s og fungerer.
6. **Idle-kutt:** proxy kutter etter 45 s stillhet → heartbeat hindrer det.
7. **Sikkerhet:** feil Origin → 403; uten cookie → 401; 6 feil passord → lockout; `../../etc/shadow` i filer → 400.
8. **Prosess-tre:** `kill` sesjon med bakgrunnsjobber → ingen foreldreløse prosesser igjen.
9. **Keymap rundtur:** for alle layout-par, `shown(encode(x)) == x`.

## Ytelsesmål (måles i CI med netsim)

- `geo`-profil: kommando sendt → første output vist < 1,5 s (≈ 2× RTT).
- Gjenopptak etter 5 s brudd (leo): live igjen < 3 s etter at nett er tilbake.
- 10 samtidige sesjoner med `yes | head -c 50M`: agentminne < 150 MB, CPU-bruk ikke 100 % på én kjerne vedvarende.

## Kodekvalitet

- `dart analyze --fatal-infos`, `dart format --set-exit-if-changed`.
- Dekning: mål 80 % for `tp_protocol` og `tp_agent/session`, `auth`, `files`.
- Alle offentlige API-er i `tp_protocol` dokumentert med `///`.
- Release-sjekkliste i `docs/` oppdateres per versjon.
