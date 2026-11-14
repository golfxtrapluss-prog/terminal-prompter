# 04 – Protokoll

Protokollversjon: **1**. Transport: WebSocket (`/api/ws`) eller SSE-fallback. Samme meldinger i begge.

## Rammeformat (WebSocket)

- **Tekstframes:** JSON kontrollmeldinger `{"t": "<type>", ...}`.
- **Binærframes:** terminaldata, for å unngå base64-overhead:

```
byte 0       : type   (0x01 = output fra server, 0x02 = input fra klient)
byte 1..16   : session_id (16 byte rå)
byte 17..24  : seq (uint64 big-endian) – kun output; for input: client_msg_id
byte 25..    : data (rå bytes, UTF-8 fra PTY)
```

## Kontrollmeldinger klient → server

| `t` | Felter | Beskrivelse |
|---|---|---|
| `hello` | `v`, `client` (versjon), `caps[]` | Første melding. Server svarer `hello`. |
| `attach` | `session` (id eller null), `name?`, `cols`, `rows`, `last_seq?` | Fest til sesjon. null = ny. |
| `detach` | `session` | |
| `resize` | `session`, `cols`, `rows` | |
| `signal` | `session`, `sig` (`INT`,`TERM`,`KILL`,`TSTP`,`EOF`) | EOF = skriv `\x04` |
| `ack` | `session`, `seq` | Bekrefter mottatt output (styrer flyt + gjenopptak) |
| `kill` | `session` | Avslutt sesjon |
| `rename` | `session`, `name` | |
| `list` | – | Be om sesjonsliste |
| `ping` | `ts` | |

## Kontrollmeldinger server → klient

| `t` | Felter | Beskrivelse |
|---|---|---|
| `hello` | `v`, `agent` (versjon), `host`, `caps[]`, `sessions[]` | |
| `attached` | `session`, `name`, `seq`, `cols`, `rows`, `truncated?` (`{from, to}`) | Etter attach. Replay følger som binærframes. |
| `sessions` | `[{id,name,created,last_seen,clients,exited?}]` | |
| `exit` | `session`, `code`, `signal?` | Prosessen avsluttet |
| `pong` | `ts` | Ekko av klientens ts → klient måler RTT |
| `ack_in` | `session`, `id` | Input med `client_msg_id` er mottatt og skrevet til PTY |
| `error` | `code`, `msg`, `session?` | Se feilkoder |
| `notice` | `level`, `msg` | F.eks. «agent oppdatert, last siden på nytt» |

## Input-idempotens

Klienten gir hver input-melding et økende `client_msg_id` (per sesjon, per klientinstans). Agenten husker siste 256 id-er per klient og ignorerer duplikater. Dette gjør det trygt å sende på nytt etter brudd uten at `rm`-kommandoen kjøres to ganger.

Klienten anser input som levert når den mottar `ack_in` (`{"t":"ack_in","session","id"}`) fra server. Ikke-bekreftet input vises med «⏳» i Prompter-historikken.

## Gjenopptak

1. Klient kobler til, sender `hello`, deretter `attach {session, last_seq}`.
2. Server: hvis `last_seq` ≥ eldste i ringbuffer → send data fra `last_seq`. Ellers send `attached.truncated` og alt som finnes.
3. Klient skriver replay til xterm og fortsetter.

## SSE-fallback

- `GET /api/sse?session=ID&last_seq=N` → `text/event-stream`. Events:
  - `event: out` / `data: {"seq":N,"d":"<base64>"}`
  - `event: ctl` / `data: <kontroll-JSON>`
  - Kommentar `: hb` hver 15 s (holder proxyer i live).
- `POST /api/sse/send` body: JSON-array av kontrollmeldinger og input `{"t":"in","session","id","d":"<base64>"}`.
- SSE bruker `Last-Event-ID` = seq for gjenopptak automatisk.

## Feilkoder

| Kode | Betydning |
|---|---|
| `auth_required` | Cookie mangler/utløpt → klient viser innlogging |
| `session_not_found` | |
| `session_limit` | `sessions.max` nådd |
| `bad_message` | |
| `version_mismatch` | Klient må lastes på nytt |
| `rate_limited` | |
| `internal` | |

## Flytkontroll

Server sender ikke mer enn 2 MB ubekreftet output per klient. Når grensen nås, pauses sendingen (PTY leses fortsatt inn i ringbuffer, så prosessen blokkeres ikke). Klient sender `ack` hver 64 KB eller hver 500 ms.

## Flerserverkjøring (v2, kun relay-modus)

Meldingene `exec_start`, `exec_cancel`, `exec_accepted`, `exec_rejected`, `exec_out` (binærframe type `0x03`) og `exec_exit` er reservert og spesifisert i doc 15. v1-agenter svarer `error {code: "unsupported"}`. Binærtype `0x03` skal ikke brukes til noe annet.

## Versjonering

`v` i `hello`. Agent støtter nåværende og forrige versjon. Nye felter er alltid valgfrie; ukjente felter ignoreres.
