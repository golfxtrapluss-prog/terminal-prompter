# 12 – Roadmap og milepæler

Hver milepæl er én avgrenset oppgave for Claude Code. Ikke start neste før akseptansekriteriene er oppfylt og testene er grønne.

## M0 – Skjelett (½ dag)
- Workspace, fire pakker, `analysis_options.yaml`, Makefile, CI som kjører `dart analyze` og tom test.
- `tp-agent version` skriver versjon.
- **Akseptanse:** `make test` og `make build` grønt; to binærer i `bin/`.
- **Status:** ✅ ferdig 14.11.2026 (commit `11c59a8`).

## M1 – PTY-kjerne (1–2 dager)
- `lib/src/pty/`: FFI-bindinger, `PtyProcess.start/write/resize/kill`, leser-isolate.
- `RingBuffer` med byte-seq.
- **Akseptanse:** komponenttestene i 11 (echo, resize/`stty size`, Ctrl-C, exit-kode, ingen foreldreløse prosesser, sid == pid). Fungerer på x64 og arm64 (CI-runner eller QEMU).
- **Status:** ✅ kode og tester ferdig 14.11.2026 (`lib/src/pty/`, `lib/src/session/ring_buffer.dart`, ADR-012). Verifisert på x64; arm64 kun kryss-kompilert, ikke kjørt.

## M2 – Protokoll + WebSocket + minimal klient (2–3 dager)
- `tp_protocol`: meldinger, codec (JSON + binærframes), tester.
- Agent: `HttpServer`, `/api/ws`, `SessionManager`, attach/input/resize/signal/output/ack.
- Klient: xterm.js-interop, Raw-modus, én sesjon. Ingen auth ennå (kun 127.0.0.1).
- **Akseptanse:** `make run`, åpne `http://127.0.0.1:7681`, kjør `htop` og `vim` normalt.
- **Status:** ✅ ferdig 14.11.2026. Verifisert i nettleser med `top` og `vi` (htop/vim ikke installert på utviklingsmaskinen), resize via `stty size`, gjenopptak etter sideoppfriskning. Integrasjonstest `packages/tp_agent/test/server_integration_test.dart`.

## M3 – Robusthet (2–3 dager)
- Gjenopptak med `last_seq`, truncation, `client_msg_id`-idempotens, `ack_in`, flytkontroll, heartbeat.
- Klientens tilstandsmaskin og backoff.
- `tp_netsim` + nettverkstester (scenario 1–6 i doc 11).
- **Akseptanse:** alle netsim-scenarier grønne med profil `geo` og `leo`.

## M4 – Prompter-modus, tastelinje og mobil (4–5 dager)
- Prompter-felt, multilinje + bracketed paste, historikk, Ctrl+R, kø ved brudd, leveringsstatus, spesialtegnrad, auto-bytte ved alternate screen, farlige-kommando-bekreftelse.
- **Tastelinje og mobil (doc 16):** alle fire rader, låsbare modifikatorer, langt trykk, gjentakelse, VisualViewport-tilpasning, Prompter som standard på mobil, knipezoom, PWA (manifest + service worker).
- **Akseptanse:** på `geo`-profil oppleves skriving som lokal; kø-scenario fungerer; på ekte iPhone og Android kan man åpne vim, redigere, lagre med `Esc :wq` og avslutte htop med `F10` kun via tastelinjen, uten at telefonens tastatur lukkes.

## M5 – Sikkerhet og innlogging (2–3 dager)
- `tp-agent init/passwd/totp`, argon2id, TOTP, **passkeys (WebAuthn)**, cookie + CSRF, Origin-sjekk, rate limit, lockout, sikkerhetshoder, auditlogg, `base_path`.
- **Akseptanse:** sikkerhetsscenariene i doc 11 grønne; ingen hemmeligheter i logger (grep-test).

## M6 – Installasjon, filer, SSE, flere sesjoner (3 dager)
- `install.sh`, `stub.sh`, systemd, proxy-snutter (Caddy/nginx/Traefik), Docker-image med `nsenter`-modus, cloud-init-mal.
- Filopplasting/-nedlasting med gjenopptak, enkel filbrowser.
- SSE-fallback.
- Sesjonsliste, nye/navngitte sesjoner, flere faner.
- `selfupdate` med ed25519.
- **Akseptanse:** fra blank Hetzner-VPS (Ubuntu) til innlogget terminal < 60 s; samme på server med Coolify via Traefik; netsim `hostile` grønn.

## M6.5 – Bootstrap-side og keymap-kompensator (2 dager)
- `tp_protocol/keymap`, innebygde layouter (no, se, dk, de, fr, uk, us), kalibreringsflyt, `loadkeys`-forslag, tegnsikker kommando, invers encoder.
- Statisk eksport (én HTML-fil) for hosting på produktdomene.
- **Akseptanse:** rundtur-tester; manuell test i Hetzner-konsoll med norsk tastatur → agent installert uten å skrive ett problemtegn.

### ➜ v1.0 Self-host-lansering (GitHub, Apache-2.0) etter M6.8

## M6.8 – Reservekoder og sjekk før avreise (2 dager)
- Reservekoder (doc 17) i agenten, «Sjekk før avreise» og tilkoblingsveiviser for rute 2 og 3.
- Venteliste med founder-lisens (Stripe Checkout, enkel landingsside) åpnes samtidig med v1-lansering.
- **Akseptanse:** sjekken oppdager hvert feilpunkt i tabellen i doc 17; en reservekode logger inn én gang og aldri igjen.

## M7 – Personal relay (v1.5) (2–3 uker)
- Se doc 17. Relay i Dart: kontoer, innlogging (passkey + reservekoder), dashbord med serverliste, linking (`tp-agent link KODE`), agent-tunnel, SNI-ruter med TLS-gjennomstrømming, sertifikater via CSR + DNS-01, wildcard-DNS.
- Stripe: Personal, reisepass, founder-lisens.
- Tilkoblingsveiviser med rute 1.
- **Akseptanse:** kriteriene i doc 17, inkludert at relay aldri ser klartekst eller agentens privatnøkkel.

### ➜ v1.5-lansering: betalt relay for privatbrukere

## M7.5 – Flerserverkjøring (v2.0) (1–2 uker, bygger på relay fra M7)
- Se doc 15. Merkelapper og grupper, jobber med kanari/parallell/rullerende/sekvensiell, stopp ved feil, tidsavbrudd, avbryt.
- Agent: `exec_start/cancel`, egen PTY per kjøring, `fleet_exec`-bryter, idempotens på `run`-ID.
- Relay: jobbmotor som eier utførelsen uavhengig av klientforbindelsen, kø for frakoblede mål, lagring av output.
- Klient: målvelger med forhåndsvisning, skalert bekreftelse, resultatvisning gruppert etter identisk output, «kjør på nytt på feilede».
- **Akseptanse:** jobb mot 20 testagenter fullføres korrekt selv om klienten kobles fra rett etter innsending; kanari stopper resten ved feil; duplikat `exec_start` kjøres én gang; farlig kommando krever kanari.

### ➜ v2.0-lansering: Pro med flerserverkjøring

## M8 – Fleet (v2.x)
- Team, roller, SSO (OIDC), sentral audit, godkjenningsflyt (også for flerserverjobber), delte jobbmaler, E2E-kryptering, passkeys.
- Pilot hos én maritim aktør.

## Estimat

M0–M6.8 (v1.0) ≈ 5 uker. M7 (v1.5, første inntekt fra abonnement) ≈ 2–3 uker til. Founder-lisenser kan selges fra v1.0 effektiv utviklingstid med Claude Code – realistisk over 1–2 friperioder i rotasjonen.
