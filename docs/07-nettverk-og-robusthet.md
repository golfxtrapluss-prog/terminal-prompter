# 07 – Nettverk og robusthet (satellitt/skip)

## Typiske nettforhold

| Nett | RTT | Tap | Særtrekk |
|---|---|---|---|
| GEO-VSAT (klassisk skip) | 550–800 ms | 1–5 % | Lav båndbredde, delt, TCP-akselerator/proxy i båtterminalen |
| LEO (Starlink Maritime) | 40–100 ms | lavt, men korte brudd ved satellittbytte | Brudd 1–10 s jevnlig |
| 4G/5G nær kyst | 30–80 ms | varierer | Bytte mellom master |
| Riggnett (bedrift) | varierer | lavt | Streng brannmur, MITM-proxy (TLS-inspeksjon), WebSocket kan være blokkert |

## Tiltak og hvor de bor

| Problem | Tiltak | Komponent |
|---|---|---|
| Høy RTT gir treg skriving | Prompter-modus: lokal redigering, én sending | Klient |
| Korte brudd | Sesjon på server + seq-basert gjenopptak, rask reconnect | Agent + klient |
| Døde forbindelser som ser levende ut | Heartbeat 15 s, timeout 30 s, begge veier | Begge |
| Proxy/brannmur kutter tomgangsforbindelser | Heartbeat < 30 s (mange proxyer kutter på 60 s) | Begge |
| WebSocket blokkert / TLS-inspeksjon ødelegger Upgrade | Automatisk fallback til SSE + POST | Begge |
| Proxy bufrer SSE | `X-Accel-Buffering: no`, padding 2 KB i første event, `Cache-Control: no-transform` | Agent |
| Lav båndbredde, mye output (`docker logs`) | Output-sammenslåing (25 ms), permessage-deflate, flytkontroll, «pause output»-knapp | Begge |
| Duplikat-kjøring ved resend | `client_msg_id`-idempotens | Begge |
| Klientfane i bakgrunnen (mobil) drepes | Ved `visibilitychange` → umiddelbar reconnect + replay | Klient |
| Store filer | Chunket, gjenopptakbar opplasting/nedlasting | Begge |

## Latensvisning

Klienten måler RTT fra `ping`/`pong` og viser glidende snitt i toppfeltet. Over 400 ms foreslås Prompter-modus hvis brukeren er i Raw.

## Lokalt ekko i Raw-modus (v2, valgfritt)

Prediktivt lokalt ekko à la Mosh: vis tastede tegn umiddelbart med understrek, bekreft når server-ekko kommer. Kun når ikke i alternate screen og ikke ved passordprompt. Komplekst – utsatt til etter MVP.

## Hvorfor ikke Mosh/UDP?

Skipsnett slipper sjelden UDP gjennom. Alt må være TCP 443 som ser ut som vanlig HTTPS-trafikk.

## Nettverkssimulering for testing

Pakken `tp_netsim` lager en TCP-proxy med justerbar forsinkelse, jitter, tap (via tilfeldige stalls/resets – ekte pakketap kan ikke simuleres i ren TCP userspace), båndbreddetak og planlagte brudd. Brukes i integrasjonstester. For manuell test på Linux: `tc qdisc add dev lo root netem delay 600ms 50ms loss 3%`.

Profiler som skal testes (se 11):

- `geo`: 650 ms ± 80, 3 % tap, 256 kbit/s
- `leo`: 60 ms, brudd 5 s hvert 3. minutt
- `hostile`: geo + WebSocket blokkert + idle-kutt på 45 s
