# CLAUDE.md – instruksjoner for Claude Code

Du bygger **Terminal Prompter**. **Hele prosjektet skrives i Dart** (agent, klient, verktøy, tester). Alle designbeslutninger står i `docs/`. Les `docs/01-systemarkitektur.md`, `docs/02-agent.md`, `docs/04-protokoll.md` og `docs/12-roadmap.md` før du skriver kode.

## Faste beslutninger (ikke endre uten å oppdatere docs/13-beslutningslogg.md)

- **Språk:** Dart ≥ 3.8 (Dart 3.8+ kreves for kryss-kompilering til linux-arm64). Null safety, `strict-casts`, `strict-raw-types`.
- **Monorepo med Dart pub workspaces:** `packages/tp_protocol` (delt), `packages/tp_agent` (server), `packages/tp_web` (klient), `packages/tp_netsim` (testverktøy).
- **Agent:** `dart compile exe` → én AOT-binær `tp-agent` (linux-x64 + linux-arm64). Bruker `dart:io` (`HttpServer`, `WebSocketTransformer`) – ikke shelf, for å holde avhengigheter minimale.
- **PTY:** Egen modul via `dart:ffi` mot libc (`posix_openpt`, `grantpt`, `unlockpt`, `ptsname_r`, `ioctl(TIOCSWINSZ)`, `read`, `write`, `close`). Barneprosess startes med `Process.start` gjennom `setsid -c` (se docs/02). Lesing fra master-fd skjer i egen `Isolate` per sesjon.
- **Klient:** Ren Dart web (`package:web` + `dart:js_interop`), kompilert med `dart compile js -O2`. **Ikke Flutter Web** (for stor for satellittnett). xterm.js brukes via JS-interop og vendres inn (ingen CDN).
- **Delt kode:** Protokollmeldinger, keymap-kompensator og validering ligger i `tp_protocol` og brukes av både agent og klient (ren Dart, ingen `dart:io`/`dart:html`).
- **Innebygde web-filer:** `tool/embed_assets.dart` genererer `lib/src/generated/assets.g.dart` (gzip + `Uint8List`-konstanter) før `dart compile exe`.
- **TLS:** Agenten kjører bak reverse proxy (Caddy/Traefik/nginx) på `127.0.0.1:7681` (standard), eller `standalone` med sertifikatfiler (`SecurityContext`). Ingen innebygd ACME i v1 (ingen moden Dart-ACME-klient) – installer setter opp Caddy ved behov.
- **Auth:** Passord (argon2id via `pointycastle`) + valgfri TOTP (egen implementasjon med `package:crypto`). Cookie `HttpOnly; Secure; SameSite=Strict`. Origin-sjekk på WS.
- **Konfig:** `/etc/tp-agent/config.toml` (`package:toml`), overstyrbar med env `TP_*`.
- **Kode og kommentarer på engelsk.** UI engelsk + norsk (i18n).

## Tillatte avhengigheter (agent)

`args`, `toml`, `crypto`, `pointycastle`, `cryptography` (ed25519-verifisering), `ffi`, `path`, `logging`, `meta`. Dev: `test`, `lints`, `mocktail`. Nye avhengigheter krever ADR.

## Tillatte avhengigheter (klient)

`web`, `tp_protocol`. Ingen andre.

## Konvensjoner

- `dart format`, `dart analyze --fatal-infos` skal være rent.
- Feil: egne `sealed class`-hierarkier for domenefeil, aldri `catch (e)` uten å logge/re-kaste.
- Strukturert logging (JSON-linjer til stdout; systemd/journald tar resten).
- Hver ny protokollmelding legges i `tp_protocol` **og** dokumenteres i `docs/04-protokoll.md` i samme commit.
- Tester ved siden av koden i hver pakke (`test/`). Nettverkstester bruker `tp_netsim`.
- Aldri logg passord, tokens eller PTY-output til fil. Auditlogg inneholder kun Prompter-input (konfigurerbart).

## Byggerekkefølge

Følg milepælene i `docs/12-roadmap.md` strengt M0 → M8. Start ikke på relay (M7) før M1–M5 er grønne.

## Kommandoer

```bash
make bootstrap    # dart pub get i workspace
make web          # dart compile js tp_web → packages/tp_agent/web_build/
make embed        # dart run tool/embed_assets.dart
make build        # bygger bin/tp-agent-linux-x64 og bin/tp-agent-linux-arm64
make run          # dart run tp_agent:tp_agent run --config dev/config.toml
make test         # dart test i alle pakker
make netsim       # integrasjonstester med simulert satellittnett
```
