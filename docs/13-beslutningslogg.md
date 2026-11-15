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

## ADR-013: Personal relay i v1.5 med TLS-gjennomstrømming
- **Kontekst:** Domene og sertifikat stopper de fleste brukere. Relay er både den enkleste tilkoblingen og hovedkilden til inntekt, men lå i v2.
- **Beslutning:** En enkel relay for privatbrukere kommer i v1.5 (M7). Relay ruter TLS på SNI uten å terminere den. Agenten lager egen TLS-nøkkel, og relay skaffer sertifikat for agentens CSR via DNS-01. Flerserverkjøring og Fleet blir i v2.
- **Konsekvenser:** Abonnementsinntekt 1–2 måneder tidligere. Relay kan ikke lese trafikk, som er et sterkt tillitsargument. Krever DNS-API, Public Suffix List-søknad og en enkel tunnelprotokoll.

## ADR-014: Reservekoder og sjekk før avreise
- **Kontekst:** Målgruppen er på sjøen i uker. Mister de telefonen eller noe er feilkonfigurert, er de utelåst lenge.
- **Beslutning:** Obligatoriske reservekoder og en «Sjekk før avreise» som verifiserer hele kjeden.
- **Konsekvenser:** Litt mer onboarding, men færre utelåste brukere og færre supporthenvendelser fra sjøen.

## ADR-011: Mobil-først med tastelinje
- **Kontekst:** En stor del av hensikten er å drifte servere fra telefon. Telefontastaturer mangler Esc, Tab, Ctrl, piltaster, F-taster og har spesialtegn gjemt.
- **Beslutning:** Klienten designes mobil-først. Alltid tilgjengelig tastelinje (doc 16) med spesialtegn, låsbare modifikatorer og egne knapper. PWA. Tastetabellen ligger i `tp_protocol`.
- **Konsekvenser:** M4 vokser med 2–3 dager. Manuell test på ekte telefoner før hver release. Sterkt salgsargument mot ttyd/Wetty (dårlige på mobil) og Termius (SSH, stopper på skipsnett).

## ADR-012: Passkeys i v1
- **Kontekst:** Lange passord + TOTP er tungvint på telefon.
- **Beslutning:** WebAuthn flyttes fra v2 til v1 (M5). Egen verifisering i agenten med `cbor` + `pointycastle`, kun attestasjon `none`.
- **Konsekvenser:** Ny avhengighet `cbor`. Mer sikkerhetskritisk kode som må testes mot kjente WebAuthn-testvektorer.

## ADR-010: Flerserverkjøring i v2, eid av relay
- **Kontekst:** Brukeren vil kjøre samme kommando på mange servere. Fra skip kan ikke klienten holde forbindelsen gjennom hele jobben.
- **Beslutning:** Funksjonen kommer i v2.0 sammen med relay. Relay eier jobben; agenten kjører hver kjøring i eget ikke-interaktivt skall; kanari er standard.
- **Konsekvenser:** v1 må reservere protokollplass (`exec_*`, binærtype `0x03`) og config-bryteren `fleet_exec`. Høy risiko (én feil treffer alle) krever sikkerhetstiltakene i doc 15. Hovedargument for Pro/Fleet.

## ADR-009: Åpen kjerne, betalt relay
- **Kontekst:** Brukere må stole på software med root-tilgang; gratis alternativer finnes.
- **Beslutning:** Agent/klient/protokoll Apache-2.0; relay og Fleet proprietært.
- **Konsekvenser:** Inntekt avhenger av relay/Fleet (se 09).

## ADR-015: Innebygde web-filer som gzip+base64-strenger
- **Kontekst:** Doc 02/CLAUDE.md skisserte `Uint8List`-konstanter. En byteliste-literal gir ~4 tegn per byte og gjør `dart format`/analyse treg på en fil på flere MB.
- **Beslutning:** `tool/embed_assets.dart` skriver hver fil gzip-komprimert som base64 i en `const Map<String, EmbeddedAsset>`. Dekoding skjer ved behov; HTTP-laget cacher. Generert fil er gitignored; verktøyet skriver en tom bunt når `web_build/` mangler, så `make test` ikke krever `make web`.
- **Konsekvenser:** ~1,33× større kildefil enn rå bytes (men gzip-gevinsten dominerer), raskere verktøykjede, ETag (SHA-256-prefiks) og `Content-Type` beregnes ved generering.

## ADR-016: PTY-leser med `poll` + vekkerør; sesjonsomfattende drap via `/proc`
- **Kontekst:** En isolate som står i blokkerende `read()` kan ikke stoppes fra hovedisolatet; `close()` på master-fd fra en annen tråd vekker ikke `read()` pålitelig. Bakgrunnsjobber (`sleep 1000 &`) havner i egne prosessgrupper, så `kill(-pgid)` alene etterlater foreldreløse prosesser.
- **Beslutning:** Leser-isolatet venter i `poll()` på master-fd **og** leseenden av et `pipe2`-rør; én byte i røret stopper leseren deterministisk. Master åpnes `O_NONBLOCK` så skriving aldri blokkerer event-løkken (EAGAIN → kort venting, tidsavbrudd → `PtyWriteTimeout`). `PtyProcess.kill()` signaliserer kommandoens gruppe og deretter alle prosesser i `/proc` med samme sesjons-id; `terminate()` eskalerer TERM → KILL.
- **Konsekvenser:** To ekstra fd-er per sesjon. `/proc`-skanning koster litt ved drap (sjelden operasjon). Interaktiv bash ignorerer SIGTERM, så drap av en sesjon tar normalt `grace` (standard 2 s) før KILL.
