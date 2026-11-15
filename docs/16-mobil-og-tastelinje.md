# 16 – Mobil og tastelinje

**Telefon er et hovedbruksområde, ikke et tillegg.** Klienten designes mobil-først: alt som er mulig på PC, skal være mulig på telefon med én hånd og uten fysisk tastatur. Tastelinjen for spesialtegn er alltid lett tilgjengelig.

## Hvorfor dette er et konkurransefortrinn

Mobile SSH-apper som Termius og Blink er gode, men de bruker SSH og stopper derfor på skipsnett. Nettbaserte terminaler som ttyd og Wetty er dårlige på mobil. Terminal Prompter kan være «Termius for nett der SSH ikke virker».

## Skjermoppsett på telefon (stående)

```
┌─────────────────────────────┐
│ ● srv1 [coolify▾]  620ms ⚙  │  ← kompakt toppfelt
├─────────────────────────────┤
│                             │
│   terminal (xterm.js)       │  ← krymper når tastaturet er oppe
│                             │
├─────────────────────────────┤
│ docker logs -f coolify█     │  ← Prompter-felt (standard på mobil)
├─────────────────────────────┤
│ Esc Tab Ctrl Alt ← ↓ ↑ → | /│  ← TASTELINJE, rad 1 (sveip for flere rader)
├─────────────────────────────┤
│  Telefonens eget tastatur   │
│  q w e r t y u i o p å      │
└─────────────────────────────┘
```

- Tastelinjen ligger **rett over telefonens tastatur** og følger det opp og ned (VisualViewport API).
- Når telefonens tastatur er lukket, ligger tastelinjen nederst på skjermen og er fortsatt synlig.
- Liggende modus gir flere kolonner til terminalen. Tastelinjen blir én rad, og Prompter-feltet blir én linje.

## Tastelinjen

### Rader (sveip sideveis eller trykk på prikkene for å bytte)

| Rad | Innhold |
|---|---|
| **1 Grunn** (standard) | `Esc` `Tab` `Ctrl` `Alt` `←` `↓` `↑` `→` `\|` `/` `-` `~` |
| **2 Tegn** | `\|` `/` `\` `~` `$` `>` `<` `&` `*` `;` `:` `"` `'` `` ` `` `=` `+` `_` `#` `@` `!` `?` `(` `)` `[` `]` `{` `}` `%` `^` |
| **3 Taster** | `F1`–`F12` `Home` `End` `PgUp` `PgDn` `Del` `Ins` |
| **4 Mine** | Egne knapper: tekst eller hele kommandoer (`docker ps`, `sudo systemctl restart coolify`) |

Rader som ikke får plass, kan rulles sideveis innenfor raden.

### Oppførsel

- **Låsbare modifikatorer:**
  - ett trykk på `Ctrl` eller `Alt` gjelder neste tast, enten fra tastelinjen eller fra telefonens tastatur
  - to trykk låser den, og et nytt trykk låser opp
  - tilstanden vises tydelig med farge
- **Langt trykk = alternativt tegn:** `/` → `\`, `-` → `_`, `'` → `"`, `(` → `)`, `[` → `]`, `{` → `}`, `<` → `>`.
- **Tastaturet skal ikke lukkes:** knappene bruker `pointerdown` + `preventDefault()`, så fokus blir i feltet og telefonens tastatur holder seg oppe. Dette er det viktigste tekniske kravet. Uten det blir linjen ubrukelig.
- **Gjentakelse:** hold inne piltaster, Del eller Backspace for å gjenta (400 ms forsinkelse, deretter 50 ms).
- **Vibrasjon:** kort vibrasjon ved trykk (`navigator.vibrate(10)`, kun Android; iOS støtter det ikke).
- **Størrelse:** minst 44 × 44 punkter per knapp. Skalering 100/125/150 % kan velges i innstillinger.

### Hva en tast gjør, avhengig av modus

| Tast | Prompter-modus | Raw-modus (sendes til PTY) |
|---|---|---|
| Vanlige tegn (`\|`, `/`, `$` …) | Settes inn ved markøren i feltet | Sendes som tegnet |
| `←` `→` | Flytter markøren i feltet | `ESC[D` / `ESC[C` (eller `ESCOD`/`ESCOC` i application cursor mode) |
| `↑` `↓` | Blar i historikken | `ESC[A` / `ESC[B` (eller `ESCOA`/`ESCOB`) |
| `Tab` | Sender feltets innhold + `\t` til skallet for fullføring, viser resultatet | `\t` |
| `Esc` | Tømmer feltet (ett trykk), lukker dialog | `\x1b` |
| `Ctrl` + bokstav | Ctrl-C/D/Z/L sendes direkte til PTY; andre brukes som snarveier i feltet | Kontrolltegn = bokstavkode & 0x1F |
| `Alt` + tast | – | `\x1b` + tasten |
| `Home`/`End` | Start/slutt av feltet | `ESC[H` / `ESC[F` |
| `PgUp`/`PgDn` | Ruller terminalvisningen | `ESC[5~` / `ESC[6~` |
| `Del` | Sletter tegn til høyre | `ESC[3~` |
| `F1`–`F4` | – | `ESCOP` `ESCOQ` `ESCOR` `ESCOS` |
| `F5`–`F12` | – | `ESC[15~` `17~` `18~` `19~` `20~` `21~` `23~` `24~` |

Application cursor mode leses fra `terminal.modes.applicationCursorKeysMode` i xterm.js. Data sendes gjennom samme input-vei som vanlige tastetrykk, så `client_msg_id`, kø og levering virker likt.

Tabellen bor i `tp_protocol/lib/src/keys.dart` (ren Dart, enhetstestet), så den kan gjenbrukes i en eventuell Flutter-app senere.

### Tilpasning

- Innstillinger → Tastelinje:
  - flytt, legg til og fjern taster per rad
  - velg standardrad
  - skjul rad 3 og 4
- Egen knapp = `{ label, send, mode: "insert" | "run" }`. `run` sender og trykker Enter. Farlige mønstre krever bekreftelse som i Prompter.
- Lagres lokalt per server, med eksport og import som JSON.
- **Pro:** synkronisering mellom enheter via relay. **Fleet:** knappeoppsett som deles i teamet («standard driftsknapper for rederiet»).

### Når tastelinjen vises

| Enhet | Standard |
|---|---|
| Telefon og nettbrett (berøring, `pointer: coarse`) | Alltid synlig |
| Nettbrett med fysisk tastatur tilkoblet | Synlig, men kan minimeres til én tynn rad |
| PC | Skjult, men slås på med knapp eller `Ctrl+Shift+K` (nyttig på fremmede tastaturoppsett) |

## Øvrige mobilkrav

- **Prompter-modus er standard på mobil.** Telefonens tastatur virker best i et vanlig tekstfelt, med sveipeskriving, diktering, autokorrektur og markørflytting med langt trykk på mellomromstasten.
- **Feltet har:** `autocapitalize="off"`, `autocorrect="off"`, `spellcheck="false"`, `autocomplete="off"`, `enterkeyhint="send"`. Autokorrektur kan slås på i innstillinger for dem som dikterer.
- **Enter på mobil sender kommandoen.** Ny linje legges til med en egen knapp på tastelinjen (`↵+`). På PC gjelder `Ctrl+Enter` som før.
- **Raw-modus på mobil:** et skjult tekstfelt fanger telefonens tastatur og videresender til xterm. Komponering og forslag (IME) håndteres via `compositionend` slik at ord ikke sendes dobbelt.
- **Skrift og zoom:** knipe med to fingre i terminalen endrer skriftstørrelse (ikke sidezoom). Kolonnetallet regnes ut på nytt og sendes som `resize`.
- **Rulling:** sveip i terminalen ruller tilbake i historikken, og en «til bunnen»-knapp dukker opp. Langt trykk markerer tekst, og deretter vises en kopier-knapp.
- **Høyde:** bruk `100dvh` og VisualViewport-hendelser, ikke `100vh`. iOS Safari regner `100vh` feil når tastaturet er oppe.
- **Ytelse:** xterm.js med DOM- eller canvas-renderer. WebGL-renderer brukes ikke på mobil (batteri og stabilitet).

## Installerbar app (PWA)

Klienten blir en Progressive Web App, slik at den kan legges på hjemskjermen og oppleves som en app:

- `manifest.webmanifest` (navn, ikoner, `display: standalone`, temafarge).
- Service worker som mellomlagrer selve klientfilene (HTML, JS, CSS, xterm). Klienten åpner da umiddelbart også på tregt nett. Den viser «frakoblet»-status i stedet for en blank side når nettet er borte. Ingen API-svar mellomlagres.
- Fullskjerm uten nettleserens adresselinje gir mer plass til terminalen.
- Fungerer i Android (Chrome) og iOS (Safari, «Legg til på Hjem-skjerm»).
- Service worker krever HTTPS, og det er uansett påkrevd.

## Innlogging på telefon: passkeys i v1

Et langt passord og en TOTP-kode er tungvint på telefon. Derfor flyttes **passkeys (WebAuthn)** fra v2 til v1 (milepæl M5), som anbefalt innloggingsmetode:

- Fingeravtrykk eller ansikt på telefonen, uten å skrive passord.
- Passordet beholdes som reserve (og trengs for å registrere første passkey).
- Agenten verifiserer WebAuthn selv: CBOR-dekoding av attestasjon (`package:cbor`) og ES256-signaturverifisering (`pointycastle`, ECDSA P-256). Kun attestasjon `none` støttes; det er nok for egne enheter.
- Flere passkeys per server (telefon, PC, nøkkel), med liste og fjerning i innstillinger.

## Varsler (v1.x, etter MVP)

Web Push for «kommando ferdig» og «sesjon avsluttet». Nyttig når en lang jobb kjører og telefonen ligger i lomma. Krever VAPID-nøkler i agenten og at PWA-en er installert (krav på iOS). Planlegges etter M6.5.

## Tester

- Enhetstester for `keys.dart`: alle taster i begge cursor-modi, Ctrl- og Alt-kombinasjoner.
- Playwright med mobil-emulering (iPhone og Pixel, stående og liggende):
  - tastelinjen lukker ikke tastaturet
  - modifikatorene låses
  - Tab-fullføring virker
  - knipezoom gir `resize`
- Manuell test på ekte iPhone (Safari og installert PWA) og Android (Chrome) før hver release. Simulatorer avslører ikke tastaturfeil godt nok.
