# 05 – Sikkerhet

Terminal Prompter gir **root-ekvivalent tilgang via nettleser på port 443**. Et svakt punkt her er like ille som en åpen SSH-server med passord «123». Sikkerhet er derfor et kjernekrav, ikke et tillegg.

## Trusselmodell

| Trussel | Tiltak |
|---|---|
| Passordgjetting / brute force | argon2id, rate limit per IP (5/min) og globalt, lockout etter `max_failed_logins`, valgfri TOTP, konstant-tid sammenligning |
| Skanning/oppdagelse | Valgfri `base_path` med tilfeldig segment; `/healthz` avslører ingenting; ingen versjon i headere |
| Cross-Site WebSocket Hijacking | Streng `Origin`-sjekk mot `public_origin`; `SameSite=Strict`-cookie |
| CSRF på API | `SameSite=Strict` + krever `Content-Type: application/json` + egen `X-TP-CSRF`-header fra cookie-verdi (double submit) |
| XSS i klient | Streng CSP, ingen `innerHTML` med serverdata, xterm renderer i canvas/DOM trygt |
| Sesjonskapring | 256-bit tilfeldig sesjons-token, kun hash lagres i minnet, `HttpOnly; Secure`, binding til User-Agent (svak), utløp + idle-utløp |
| MITM | TLS påkrevd for alt utenom localhost; HSTS i standalone |
| Path traversal i filer | `filepath.Clean` + sjekk prefiks mot rot etter `EvalSymlinks` |
| Kompromittert oppdatering | `selfupdate` verifiserer ed25519-signatur (offentlig nøkkel innbakt i binær) + SHA-256 |
| Ondsinnet installasjonsskript (MITM under bootstrap) | Skript lastes over HTTPS; publiser SHA-256 på nettsiden; binær signaturverifiseres av skriptet |
| Tap av enhet (stjålet laptop med innlogget fane) | Kort `session_ttl`, «logg ut alle»-knapp, liste over aktive innlogginger |
| Innsider/revisjon | Append-only auditlogg: innlogginger, sesjonsstart/-slutt, kommandoer fra Prompter, filoverføringer |

## Autentisering

- Første oppsett: `tp-agent init` genererer et sterkt tilfeldig passord (vises én gang) eller lar brukeren sette eget (min. 12 tegn, sjekk mot topp-10k-liste).
- argon2id-parametre: m=64 MiB, t=3, p=2 (`pointycastle` Argon2BytesGenerator; kjøres i `Isolate.run` så innlogging ikke blokkerer event-løkken).
- TOTP: RFC 6238 (egen implementasjon, HMAC-SHA1 fra `package:crypto`, testet mot RFC-vektorer), 30 s, ±1 vindu, gjenbruksvern (siste brukte kode huskes).
- **v1: WebAuthn/passkeys** – anbefalt metode, særlig på telefon (doc 16). Passord beholdes som reserve.
- v2 (relay): OIDC/SSO for bedriftskunder (Entra ID, Google).

## Reservekoder

10 engangskoder for når passkey-enheten er tapt (f.eks. telefon mistet på sjøen). Lagres som argon2id-hasher, virker én gang, ny generering ugyldiggjør gamle. Detaljer i doc 17.

## Presiseringer fra implementasjonen (M5)

- **Ingen passord, ingen tjeneste:** `tp-agent run` nekter å starte uten `password_hash`, også på 127.0.0.1 (proxy-modus lytter på loopback, men er nåbar via reverse proxy).
- **Lockout gjelder passord og reservekoder,** globalt på tvers av IP-er, etter `max_failed_logins` påfølgende feil. Passkey-innlogging er ikke omfattet, slik at en angriper som gjetter passord ikke kan stenge eieren ute. Alle innloggingsforsøk er i tillegg begrenset til 5/min per IP og 30/min totalt. I proxy-modus brukes siste adresse i `X-Forwarded-For` når forespørselen kommer fra loopback.
- **Feilmeldinger** sier aldri hvilken faktor som var feil (`invalid_credentials`).
- **TOTP** krever passord + kode i samme forespørsel. Siste brukte tidssteg lagres i tilstandsfilen, så en kode virker bare én gang.
- **Innloggingsøkter** ligger bare i minnet (SHA-256 av token). Absolutt levetid `session_ttl`, idle-utløp `idle_timeout`, og bytte av User-Agent avslutter økten. Omstart av agenten logger alle ut.
- **Passkeys:** kun ES256 (P-256), brukerverifisering kreves, attestasjonsutsagn ignoreres (vi stoler på nøkkelen, ikke på produsenten). Telleren må øke når den ikke er 0 (oppdager klonede nøkler). rpId er vertsnavnet i `public_origin` eller `Host`.
- **Reservekoder:** argon2id (m=19 MiB, t=2, p=1) med felles salt per sett, slik at hvert forsøk koster én hash uansett hvor mange koder som er igjen. Trygt fordi hver kode er en tilfeldig hemmelighet på ~49 bit.
- **Passordliste:** «topp-10k» er utvidet med NCSC-listen over de 100 000 mest brukte passordene (SecLists), filtrert til oppføringer på minst 12 tegn, siden kortere passord uansett avvises (1 197 oppføringer). Se ADR-018.
- **Filer:** `config.toml`, `auth.json` og `audit.jsonl` skrives med rettigheter 0600; konfig og tilstand skrives atomisk (midlertidig fil + rename).
- **Revisjonslogg** roteres ved 10 MB (én eldre fil beholdes). Hendelser: `login_ok`, `login_fail`, `lockout`, `logout`, `logout_all`, `passkey_added`, `passkey_removed`, `backup_codes_generated`, `backup_code_used`, `session_start`, `session_end`, `cmd`.

## Relay og tillit (v1.5)

Relay ruter TLS gjennom uten å terminere den (SNI-ruting), og agentens TLS-privatnøkkel lages og blir på serveren. Relay kan derfor ikke lese kommandoer eller output. Dette dokumenteres åpent på nettsiden, fordi det er hovedargumentet for å stole på tjenesten. Detaljer i doc 17.

## Sikkerhetshoder

```
Strict-Transport-Security: max-age=31536000   (kun standalone)
Content-Security-Policy: default-src 'self'; connect-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'
X-Content-Type-Options: nosniff
Referrer-Policy: no-referrer
Permissions-Policy: camera=(), microphone=(), geolocation=()
Cache-Control: no-store   (API)
```

## Auditlogg-format (JSONL)

```json
{"ts":"2026-11-14T13:20:01Z","ev":"login_ok","ip":"203.0.113.9","ua":"..."}
{"ts":"...","ev":"session_start","sid":"K3F...","name":"coolify"}
{"ts":"...","ev":"cmd","sid":"K3F...","line":"docker restart coolify"}
{"ts":"...","ev":"upload","path":"/home/tp/backup.tar","bytes":10485760}
```

Raw-modus-tastetrykk logges ikke (ville inneholdt passord skrevet til `sudo`). Prompter-linjer logges, men linjer som følger en passord-prompt (`[sudo] password`, `Password:`) i output maskeres automatisk.

## Prinsipper for koden

- Ingen hemmeligheter i URL-er (unntak: valgfri `base_path`, som er obskurering, ikke sikkerhet – dokumenter det slik).
- Alle grenser har tak: meldingsstørrelse (1 MB), antall sesjoner, upload-størrelse, antall WS-forbindelser per innlogging (10).
- `dart analyze --fatal-infos`, `dart test` og avhengighetsrevisjon (`dart pub outdated` + OSV-skanner mot pubspec.lock) i CI.
- Ekstern sikkerhetsgjennomgang før betalt lansering.
