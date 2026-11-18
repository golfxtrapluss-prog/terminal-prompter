# 04 – Protokoll

Protokollversjon: **1**. Transport: WebSocket (`/api/ws`) eller SSE-fallback. Samme meldinger i begge.

## Rammeformat (WebSocket)

- **Tekstframes:** JSON kontrollmeldinger `{"t": "<type>", ...}`.
- **Binærframes:** terminaldata, for å unngå base64-overhead:

```
byte 0       : type   (0x01 = output fra server, 0x02 = input fra klient,
                       0x04 = input fra Prompter-feltet; 0x03 reservert v2)
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

## Presiseringer fra implementasjonen (M2)

- **Kapabiliteter** (`caps`): `binary` (terminaldata i binærframes), `ack_in` (agenten bekrefter input), `sse` (agenten tilbyr SSE-fallback). Ukjente strenger ignoreres.
- **`attach` uten `last_seq`** gir full replay av hele ringbufferen (fra eldste byte). Med `last_seq` sendes bare det som mangler; er `last_seq` eldre enn bufferen, settes `attached.truncated = {from: last_seq, to: eldste}`.
- **`attached.seq`** er sesjonens nåværende `seq` (neste byte som produseres). Replay-frames som følger har egne `seq`-verdier, og klienten regner `last_seq = seq + len(data)` for siste frame.
- **`detach`, `resize`, `signal`, `ack`** og input-frames krever at forbindelsen er festet til sesjonen; ellers svares `error {code: "session_not_found"}`.
- **`kill`** og **`rename`** besvares med en oppdatert `sessions`-melding til avsenderen; festede klienter får `exit` ved `kill`.
- **Sesjons-ID** i JSON er 26 tegn liten base32 (RFC 4648-alfabet, uten padding) av de 16 rå bytene.
- **Tidsstempler** (`created`, `last_seen`) er ISO 8601 i UTC.
- Output-frames er maks 64 KB; input-frames maks 1 MB; kontrollmeldinger maks 1 MB.

### Tillegg fra M3 (robusthet)

- **`hello.instance`** (valgfri streng, maks 64 tegn): tilfeldig ID per klientinstans (fane). Agenten husker siste 256 `client_msg_id` **per sesjon og instans**, så input som sendes på nytt etter en gjenoppkobling (ny forbindelse, samme instans) skrives bare én gang, men bekreftes med `ack_in` hver gang. Uten `instance` gjelder idempotensen bare innenfor én forbindelse.
- **Flytkontroll i praksis:** agenten sender live output til en klient inntil 2 MB er ubekreftet, og pauser deretter. Ved `ack` som bringer ubekreftet under 1 MB tas det igjen fra ringbufferen. Er klientens posisjon overskrevet i mellomtiden (eller ligger mer enn 4 MB bak), lukkes forbindelsen med WebSocket-kode 1008 «slow consumer»; klienten kobler til igjen med `last_seq` og får `attached.truncated`. Minnet per treg klient er dermed begrenset av ringbufferen.
- **Heartbeat:** agenten sender WebSocket-ping-rammer (protokollnivå, usynlige for applikasjonen) hvert `transport.heartbeat` (standard 15 s). Uteblir pong innen **samme intervall**, lukker agenten forbindelsen (dart:io-semantikk: tidsavbrudd = intervall). Klienten sender i tillegg `ping` hvert 15 s og regner forbindelsen som død etter 30 s uten mottatte rammer. Heartbeat må være lengre enn RTT; for satellitt er 15 s god margin.
- **Klientens gjenoppkobling:** backoff 0,5/1/2/4/8/10 s med ±25 % jitter, nullstilles når forbindelsen er live; umiddelbart nytt forsøk ved `online`-hendelse og når fanen blir synlig. Ubekreftet input sendes på nytt med samme `client_msg_id` etter `attached`.

### Tillegg fra M5 (sikkerhet)

- **Rammetype `0x04`** har samme layout som `0x02`, men markerer at input kommer fra Prompter-feltet. Agenten skriver slike linjer til revisjonsloggen (`ev: "cmd"`) når `audit.log_input = true`. Rå tastetrykk (`0x02`) logges aldri. Er siste output-linje en passordprompt (`password:`, `passord:`, `passphrase:`, `PIN:`), maskeres linjen som `***`. Idempotens og `ack_in` er som for `0x02`.
- **Innlogging kreves:** `/api/ws` svarer `401` uten gyldig `tp_session`-cookie og `403` når `Origin` ikke er tillatt, før oppgradering. Maks 10 samtidige WebSockets per innlogging (`429`).
- **Lukkekode `4401`:** agenten lukker WebSocket med 4401 når innloggingen avsluttes (utlogging, «logg ut overalt», utløp). Klienten spør da `GET /api/me`; ved `401` viser den innloggingssiden og slutter å koble til.
- **Tillatt `Origin`:** lik `public_origin` når den er satt; ellers må den være `http://` eller `https://` + `Host`-headeren.
- **POST-krav:** `Content-Type: application/json`, tillatt `Origin`, og for innloggede kall `X-TP-CSRF` lik verdien i `tp_csrf`-cookien (dobbel innsending, bundet til innloggingen).

## Versjonering

`v` i `hello`. Agent støtter nåværende og forrige versjon. Nye felter er alltid valgfrie; ukjente felter ignoreres.
