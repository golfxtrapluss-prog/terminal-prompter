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
- **Status:** ✅ ferdig 15.11.2026. `make netsim` kjører scenario 1–4 og 6 fra doc 11 mot `geo` og `leo`; scenario 5 (WS blokkert → SSE) venter på SSE-transporten i M6. Klientens tilstandsmaskin testes på VM med falsk transport (`packages/tp_web/test/connection_test.dart`).

## M4 – Prompter-modus, tastelinje og mobil (4–5 dager)
- Prompter-felt, multilinje + bracketed paste, historikk, Ctrl+R, kø ved brudd, leveringsstatus, spesialtegnrad, auto-bytte ved alternate screen, farlige-kommando-bekreftelse.
- **Tastelinje og mobil (doc 16):** alle fire rader, låsbare modifikatorer, langt trykk, gjentakelse, VisualViewport-tilpasning, Prompter som standard på mobil, knipezoom, PWA (manifest + service worker).
- **Akseptanse:** på `geo`-profil oppleves skriving som lokal; kø-scenario fungerer; på ekte iPhone og Android kan man åpne vim, redigere, lagre med `Esc :wq` og avslutte htop med `F10` kun via tastelinjen, uten at telefonens tastatur lukkes.
- **Status:** 🟡 implementert 18.11.2026 og verifisert i nettleser med mobilemulering (375×812 stående, 812×375 liggende) og PC-visning: Prompter, historikk, Ctrl+R, snutter, egne knapper, farlige kommandoer, kø ved brudd (også over sideoppfriskning uten nett), leveringsstatus, auto-bytte til Rå ved alternate screen, `vim` med `Esc :wq` og `htop` med `F10` kun via tastelinjen, Ctrl fra tastelinjen + vanlig tast = `\x03`, PWA med offline-start og oppdatering. **Gjenstår:** manuell test på ekte iPhone og Android, og Playwright-tester med mobilemulering (doc 16).

## M5 – Sikkerhet og innlogging (2–3 dager)
- `tp-agent init/passwd/totp`, argon2id, TOTP, **passkeys (WebAuthn)**, cookie + CSRF, Origin-sjekk, rate limit, lockout, sikkerhetshoder, auditlogg, `base_path`.
- **Akseptanse:** sikkerhetsscenariene i doc 11 grønne; ingen hemmeligheter i logger (grep-test).
- **Status:** ✅ ferdig 18.11.2026. `packages/tp_agent/test/security_test.dart`: feil Origin → 403, uten cookie → 401, lockout etter 5 feil (på tvers av IP-er), rate limit per IP, CSRF, TOTP med gjenbruksvern, reservekoder én gang, utlogging lukker WebSocket (4401), revisjonslogg med maskering, grep-test uten funn i logg/revisjonslogg/tilstandsfil. Krypto testet mot RFC 9106, RFC 6238 og RFC 6979; WebAuthn mot programvare-autentikator. Verifisert i nettleser (mobilvisning): innlogging, reservekoder, utlogging overalt. Path traversal i filer (scenario 7, siste del) kommer med filoverføring i M6. Passkey-registrering i ekte nettleser/telefon er ikke testet ennå.

## M6 – Installasjon, filer, SSE, flere sesjoner (3 dager)
- `install.sh`, `stub.sh`, systemd, proxy-snutter (Caddy/nginx/Traefik), Docker-image med `nsenter`-modus, cloud-init-mal.
- Filopplasting/-nedlasting med gjenopptak, enkel filbrowser.
- SSE-fallback.
- Sesjonsliste, nye/navngitte sesjoner, flere faner.
- `selfupdate` med ed25519.
- **Akseptanse:** fra blank Hetzner-VPS (Ubuntu) til innlogget terminal < 60 s; samme på server med Coolify via Traefik; netsim `hostile` grønn.
- **Status:** 🟡 implementert 18.11.2026. Grønt: netsim `hostile` (scenario 5, SSE gjennom blokkert WebSocket og idle-kutt), filoverføring med gjenopptak og Range (også i nettleser, 700 KB byte-for-byte), path traversal → 400, flere/navngitte sesjoner i nettleser, `selfupdate` mot lokal signert release (feil signatur, manipulert `SHA256SUMS`, byttet binær og manglende nøkkel avvises), `install.sh` ende-til-ende i sandkasse under dash og BusyBox, `uninstall`. **Ikke verifisert:** installasjon på blank Hetzner-VPS og på Coolify (krever ekte server), Docker-imaget (Docker mangler lokalt), `release.yml` (repoet er ikke på GitHub ennå), Caddy-installasjon og OpenRC-tjeneste på ekte maskiner.

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
