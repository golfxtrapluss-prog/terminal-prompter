# Terminal Prompter – arkitekturpakke

Komplett arkitekturgrunnlag (Dart) for å bygge **Terminal Prompter**: en nettbasert terminal-proxy som gir full shell-tilgang til servere over HTTPS/443 fra nettverk der SSH er blokkert (skip, rigger, satellitt), og som omgår tegnfeilene i VNC-/nettleserkonsoller.

## Slik bruker du pakken i Claude Code

1. Pakk ut zip-filen i en tom mappe og `git init`.
2. Start Claude Code i mappen. `CLAUDE.md` leses automatisk og forteller Claude Code byggerekkefølge, konvensjoner og hva som er bestemt.
3. Gi første oppdrag: «Les docs/ og start på milepæl M1 i docs/12-roadmap.md».
4. Ta én milepæl om gangen. Hver milepæl har akseptansekriterier som kan testes.

## Innhold

| Fil | Innhold |
|---|---|
| `CLAUDE.md` | Instruksjoner til Claude Code (konvensjoner, regler, byggerekkefølge) |
| `docs/00-visjon-og-scope.md` | Problem, målgruppe, scope, ærlig konkurranseanalyse |
| `docs/01-systemarkitektur.md` | Komponenter, dataflyt, driftsmodi, diagrammer |
| `docs/02-agent.md` | Serveragenten i detalj (Dart, FFI-PTY, sesjoner, filoverføring) |
| `docs/03-klient.md` | Nettleserklienten i Dart web (Prompter, xterm.js-interop, UI) |
| `docs/04-protokoll.md` | WebSocket- og fallback-protokoll, meldingsformater |
| `docs/05-sikkerhet.md` | Trusselmodell, autentisering, herding, revisjonslogg |
| `docs/06-bootstrap-og-installasjon.md` | Hvordan få agenten inn via en ødelagt VNC-konsoll |
| `docs/07-nettverk-og-robusthet.md` | Satellittnett: latens, pakketap, gjenoppkobling, fallback |
| `docs/08-keymap-kompensator.md` | Tegnoversetteren: kalibrering og invers mapping |
| `docs/09-saas-relay-og-inntekt.md` | Relay-tjeneste, multi-server, lisens, prising, inntekt |
| `docs/10-prosjektstruktur.md` | Repo-tre, moduler, konfigurasjon |
| `docs/11-testing-og-kvalitet.md` | Teststrategi, nettverkssimulering, CI |
| `docs/12-roadmap.md` | Milepæler M0–M8 med akseptansekriterier |
| `docs/13-beslutningslogg.md` | ADR-er: hvorfor Dart, PTY via FFI, dart2js, osv. |
| `docs/14-ordliste.md` | Begreper |
| `docs/15-flerserverkjoring.md` | Flerserverkjøring (v2): samme kommando på mange servere |
| `docs/16-mobil-og-tastelinje.md` | Mobil-først: tastelinje for spesialtegn, PWA, passkeys |
| `docs/17-tilkobling-og-onboarding.md` | Trygg HTTPS-tilkobling: relay (v1.5), eget domene, veiviser, reservekoder, sjekk før avreise |

Versjon 1.3 – 15.11.2026 (tilkobling og onboarding, relay flyttet til v1.5, reservekoder, sjekk før avreise)
