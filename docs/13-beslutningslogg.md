# 13 – Beslutningslogg (ADR)

Format: Kontekst → Beslutning → Konsekvenser. Nye beslutninger legges til nederst.

## ADR-001: Dart for hele prosjektet
- **Kontekst:** Eierens valg. Behov for én kodebase for server, nettklient og (senere) relay og mobilapp.
- **Beslutning:** Dart overalt. Agent som AOT-binær, klient som dart2js, delt `tp_protocol`.
- **Konsekvenser:** + Delt protokoll-/keymap-kode, sterk typing, én verktøykjede, Flutter-mobilapp senere uten ny protokollkode. − Ingen innebygd PTY (løst med FFI, ADR-003), ingen moden ACME-klient (ADR-005), binær dynamisk lenket mot glibc (Alpine trenger gcompat).

## ADR-002: Ekte PTY, ikke subprocess med pipes
- **Kontekst:** Prosjektbeskrivelsen nevnte subprocess. Uten PTY virker ikke vim, htop, sudo-passord, farger, Ctrl-C eller jobbkontroll.
- **Beslutning:** PTY for alle sesjoner.
- **Konsekvenser:** Krever FFI-modul og Linux-spesifikk kode.

## ADR-003: PTY via posix_openpt + `setsid -c`, ikke forkpty
- **Kontekst:** `fork()` i flertrådet Dart-VM er usikkert.
- **Beslutning:** Åpne PTY-par via FFI; start barn med `Process.start` (normal modus) gjennom `sh -c 'exec setsid -c …'`; les master-fd i egen isolate.
- **Konsekvenser:** Avhengig av `setsid` med `-c` på målsystemet (util-linux eller BusyBox). Installer sjekker.

## ADR-004: Dart web (dart2js) + xterm.js, ikke Flutter Web
- **Kontekst:** Satellittnett, 64–256 kbit/s. Flutter Web (CanvasKit) er flere MB.
- **Beslutning:** `package:web` + JS-interop mot vendret xterm.js.
- **Konsekvenser:** Liten klient (< 450 KB gzip), moden terminalemulering. UI bygges med enkel DOM-kode.

## ADR-005: TLS via reverse proxy som standard
- **Kontekst:** Ingen moden ACME-implementasjon i Dart; de fleste målservere har allerede Traefik/Caddy/nginx (f.eks. Coolify).
- **Beslutning:** Standardmodus `proxy` på 127.0.0.1:7681. `standalone` støtter kun sertifikatfiler. Installer setter opp Caddy hvis ingen webserver finnes.
- **Konsekvenser:** Ett ekstra program på rene servere, men robust og automatisk sertifikatfornyelse.

## ADR-006: Sesjonen bor på serveren; byte-basert seq
- **Kontekst:** Hyppige brudd på skipsnett.
- **Beslutning:** PTY lever uavhengig av forbindelsen; output nummereres per byte; ringbuffer.
- **Konsekvenser:** Sømløst gjenopptak; minnebruk begrenset av `scrollback_bytes`.

## ADR-007: WebSocket med SSE-fallback
- **Kontekst:** Bedriftsproxyer med TLS-inspeksjon blokkerer ofte WS Upgrade.
- **Beslutning:** Transportgrensesnitt med to implementasjoner; automatisk valg.
- **Konsekvenser:** Litt mer kode; virker i praktisk talt alle nett som slipper HTTPS.

## ADR-008: Tegnoversettelse kun i bootstrap
- **Kontekst:** Prosjektbeskrivelsen la tegnoversettelse i den løpende klienten. Når agenten kjører, går UTF-8 urørt over WebSocket – det er ingenting å oversette.
- **Beslutning:** Keymap-kompensator er et eget bootstrap-verktøy; den løpende terminalen gjør ingen oversettelse.
- **Konsekvenser:** Enklere og mer korrekt kjerne. Kompensatoren blir et tydelig, demonstrerbart salgsargument.

## ADR-010: Flerserverkjøring i v2, eid av relay
- **Kontekst:** Brukeren vil kjøre samme kommando på mange servere. Fra skip kan ikke klienten holde forbindelsen gjennom hele jobben.
- **Beslutning:** Funksjonen kommer i v2.0 sammen med relay. Relay eier jobben; agenten kjører hver kjøring i eget ikke-interaktivt skall; kanari er standard.
- **Konsekvenser:** v1 må reservere protokollplass (`exec_*`, binærtype `0x03`) og config-bryteren `fleet_exec`. Høy risiko (én feil treffer alle) krever sikkerhetstiltakene i doc 15. Hovedargument for Pro/Fleet.

## ADR-009: Åpen kjerne, betalt relay
- **Kontekst:** Brukere må stole på software med root-tilgang; gratis alternativer finnes.
- **Beslutning:** Agent/klient/protokoll Apache-2.0; relay og Fleet proprietært.
- **Konsekvenser:** Inntekt avhenger av relay/Fleet (se 09).
