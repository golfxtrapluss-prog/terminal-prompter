# 03 – Nettklienten (Dart web)

## Teknologi

- **Ren Dart web**: `package:web` + `dart:js_interop`, kompilert med `dart compile js -O2 --no-source-maps` (release). Forventet størrelse 150–300 KB gzip for appkoden.
- **xterm.js** (+ `addon-fit`, `addon-web-links`, `addon-search`, `addon-unicode11`) vendres inn under `packages/tp_web/web/vendor/xterm/` og lastes med `<script>` før Dart-koden. Dart snakker med det via `@JS()`-extension types (`lib/src/interop/xterm.dart`).
- **Hvorfor ikke Flutter Web:** CanvasKit-runtime er flere MB – uakseptabelt på 64–256 kbit/s satellitt, og tekstmarkering/innliming i terminal er svakere. Flutter kan vurderes senere for en egen mobilapp som bruker samme `tp_protocol`.
- **Ingen eksterne ressurser** (fonter, CDN). Alt serveres av agenten.

## Skjermoppsett

```
┌──────────────────────────────────────────────────────────────┐
│ ● tp.example.com   [coolify ▾] [+ ny]   ⟳ 620ms  ⇅ WS  ⚙  ⏻ │  ← sesjoner, latens, transport
├──────────────────────────────────────────────────────────────┤
│                                                              │
│                xterm.js – terminalvisning                    │
│                                                              │
├──────────────────────────────────────────────────────────────┤
│ [Prompter] [Raw]   📎 snutter  ⬆ last opp  ⬇ last ned         │
│ ┌──────────────────────────────────────────────────────────┐ │
│ │ docker logs -f coolify-proxy | grep -i error             │ │  ← Prompter-felt (multilinje)
│ └──────────────────────────────────────────────────────────┘ │
│ Ctrl+Enter send · ↑↓ historikk · Ctrl+R søk           [Send] │
│ Esc Tab Ctrl Alt ← ↓ ↑ → | / - ~      ● ○ ○ ○              │  ← tastelinje (doc 16), sveip for flere rader
└──────────────────────────────────────────────────────────────┘
```

> **Mobil-først:** Oppsettet over er PC-visningen. Telefonvisning, tastelinjen for spesialtegn og alle mobilkrav er spesifisert i **doc 16** og har forrang ved konflikt.

## Moduser

| Modus | Oppførsel | Bruk |
|---|---|---|
| **Prompter** (standard) | Tekst skrives i lokalt felt. Send = hele teksten + `\r` i én melding. Null ekko-forsinkelse. | Det meste på dårlig nett |
| **Raw** | Fokus i xterm; hvert tastetrykk sendes direkte. | vim, nano, htop, less, interaktive prompts |

Bytte: `Ctrl+Shift+Space` eller knapp. Klienten foreslår Raw automatisk ved alternate screen (`\x1b[?1049h`) og tilbake ved `\x1b[?1049l`.

## Prompter-funksjoner

- **Multilinje:** `Enter` = ny linje, `Ctrl+Enter` = send (konfigurerbart). Flere linjer sendes med bracketed paste (`\x1b[200~ … \x1b[201~`) når skallet har aktivert det.
- **Historikk:** lokal (localStorage per server, via trygg wrapper med try/catch), `Ctrl+R` søk.
- **Snutter:** navngitte kommandoer med variabler (`docker logs -f {{container}}`), eksport/import JSON.
- **Farlige kommandoer:** regex-liste gir bekreftelsesdialog (konfigurerbar).
- **Signaler:** Ctrl-C/D/Z virker også i Prompter-modus.
- **Tastelinje:** spesialtegn, låsbare Ctrl/Alt, piltaster, F-taster og egne knapper (doc 16).
- **Kø ved brudd:** kommandoer merkes «venter på nett», sendes ved gjenopprettet forbindelse; kø eldre enn 60 s krever ny bekreftelse.
- **Leveringsstatus:** ⏳ til `ack_in` mottas, ✓ etterpå.

## Tilkoblingsmotor (`lib/src/conn/connection.dart`)

```
disconnected → connecting → authCheck → attaching → live
      ↑             │            │           │        │
      └─── backoff ◄┴────────────┴───────────┴────────┘
```

- `sealed class ConnState` + `StreamController<ConnState>` som UI lytter på.
- WS først; to WS-feil på rad mens `/api/me` svarer → SSE, husk valget 24 t.
- Backoff 0.5/1/2/4/8/10 s med jitter; umiddelbart forsøk ved `online`-event og `visibilitychange`.
- Heartbeat 15 s, død etter 30 s uten data.
- `last_seq` per sesjon sendes i `attach`.

## Pakkestruktur (`packages/tp_web`)

```
web/index.html
web/styles.css
web/main.dart                       inngang
web/vendor/xterm/                   xterm.js + addons (vendret)
lib/src/app.dart                    ruting login ↔ terminal ↔ bootstrap
lib/src/interop/xterm.dart          @JS extension types for Terminal, FitAddon …
lib/src/conn/connection.dart        tilstandsmaskin
lib/src/conn/ws_transport.dart      web.WebSocket (binaryType = arraybuffer)
lib/src/conn/sse_transport.dart     web.EventSource + fetch POST
lib/src/ui/terminal_view.dart
lib/src/ui/prompter.dart            felt, historikk, snutter, kø
lib/src/ui/keybar.dart              tastelinje: rader, modifikatorer, langt trykk, gjentakelse
lib/src/ui/viewport.dart            VisualViewport, tastaturhøyde, dvh
lib/src/ui/touch.dart               knipezoom, rulling, markering
lib/src/pwa/                        service worker-registrering
web/manifest.webmanifest, web/sw.js, web/icons/
lib/src/ui/topbar.dart
lib/src/ui/files.dart
lib/src/ui/settings.dart
lib/src/ui/bootstrap_page.dart      keymap-kompensator (logikk i tp_protocol)
lib/src/storage.dart                trygg localStorage-wrapper
lib/src/i18n/{en,no}.dart
```

UI bygges med enkle DOM-hjelpere (`HTMLElement`-fabrikker) – ingen komponentbibliotek.

## Sikkerhet i klienten

- Aldri `innerHTML` med data fra server; bruk `textContent`.
- CSP fra agenten: `default-src 'self'; connect-src 'self'; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'` (dart2js-output trenger ikke `unsafe-eval`).
- CSRF-token fra cookie sendes som `X-TP-CSRF` på alle POST.
