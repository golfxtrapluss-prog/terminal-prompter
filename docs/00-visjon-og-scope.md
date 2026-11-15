# 00 – Visjon og scope

## Problemet

Folk som drifter servere fra skip, rigger og andre begrensede nett møter to problemer samtidig:

1. **SSH virker ikke.** Satellitt- og skipsbrannmurer slipper ofte gjennom TCP-håndtrykket, men dropper pakkene etterpå (stille pakketap). Bare HTTPS på 443 fungerer stabilt.
2. **Nødkonsollen (VNC/noVNC hos Hetzner, DigitalOcean, OVH, Proxmox osv.) ødelegger tegn.** Tastaturoppsett-mismatch mellom nettleser, VNC-lag og serverens konsoll-keymap gjør at `:` `>` `(` `$` `|` `/` blir feil eller forsvinner. Lim inn virker dårlig eller ikke i det hele tatt.

Resultat: man er utelåst fra egen server, eller må skrive kommandoer med prøving og feiling.

## Løsningen i én setning

En liten agent på serveren som tilbyr en ekte terminal i nettleseren over HTTPS/443, med en kommando-«prompter» som er bygget for høy latens og ustabilt nett – og et bootstrap-verktøy som får agenten installert selv gjennom en ødelagt VNC-konsoll.

## Viktig innsikt for arkitekturen

Tegnproblemet finnes **bare i VNC-konsollen**. Når agenten kjører, går all tekst som UTF-8 over WebSocket – det er ingenting å «oversette». Derfor har produktet to tydelig adskilte deler:

| Del | Når | Løser |
|---|---|---|
| **Keymap-kompensator + bootstrap** | Én gang, før agenten finnes | Tegnfeil i VNC |
| **Agent + nettklient** | Resten av tiden | Blokkert SSH, dårlig nett, komfortabel bruk |

## Telefon som hovedenhet

En stor del av hensikten er å kunne drifte servere **fra telefonen**. Klienten designes mobil-først, med alltid tilgjengelig tastelinje for spesialtegn og terminaltaster, installerbar som app (PWA) og med passkey-innlogging. Se doc 16.

## Målgruppe

- Primær: offshore-/maritimt personell som drifter egne eller firmaets VPS-er (inkl. egen bruk: Hetzner + Coolify fra skip).
- Sekundær: maritime IT-avdelinger, subsea-selskaper, riggoperatører, MSP-er som drifter kunders servere fra restriktive nett.
- Tertiær: alle bak bedriftsbrannmurer som kun slipper 443.

## Utvidet målgruppe: restriktive nett

Samme problem finnes på cruiseskip (VPN ofte blokkert på enklere wifi-pakker), fly, hotell, tog og konferanse-wifi. Disse nås med relay og reisepass (doc 17). Mindre verdi per bruker enn offshore B2B, men større volum.

## Scope v1 (MVP)

- Agent (Linux amd64/arm64), selvhostet, én server.
- Nettklient med full terminal (xterm.js) + Prompter-felt (komponer, historikk, snutter, multilinje).
- Mobil-først: tastelinje for spesialtegn og terminaltaster, PWA, passkeys (doc 16).
- Sesjoner som overlever frakobling (gjenoppta der du var).
- Fallback-transport når WebSocket blokkeres.
- Filopplasting/-nedlasting over HTTPS.
- Bootstrap-side med keymap-kompensator og trygg installasjonskommando.

## Utenfor scope v1

- Windows-servere, grafisk desktop, port-forwarding/tunnel, SFTP-protokoll, egen app i app-butikkene (PWA dekker behovet i v1).

## Ærlig konkurranseanalyse

Påstanden «det finnes ingen løsning» holder ikke helt. Nettbaserte terminaler finnes:

| Verktøy | Hva det er | Svakhet for vår målgruppe |
|---|---|---|
| ttyd, GoTTY, Wetty, Shell In A Box | Web-terminal over HTTP(S) | Ingen sesjonsgjenopptak ved brudd, ingen prompter, ingen bootstrap-hjelp, krever inngående port + egen TLS-oppsett |
| Cockpit | Serveradmin i nettleser | Tungt, port 9090 som standard, ikke laget for satellittnett |
| Apache Guacamole | Gateway for SSH/RDP/VNC | Krever egen gateway-server, komplisert |
| Termius, Blink (mobile SSH-apper) | Gode på mobil | Bruker SSH → stopper på skipsnett |
| Teleport, Cloudflare Access (browser SSH), Tailscale SSH | Bedriftsklasse tilgangsplattformer | Krever konto/infrastruktur, overkill for enkeltpersoner, noen bruker UDP/ikke-443 som skipsnett stopper |

**Differensiering som faktisk er forsvarbar:**

1. Bygget for satellittnett: gjenopptak med sekvensnumre, lokal redigering (ingen ekko-forsinkelse), fallback til SSE, aggressiv heartbeat.
2. Bootstrap gjennom ødelagt VNC (keymap-kompensator + tegnsikker installasjon) – ingen konkurrent gjør dette.
3. Relay-modus (v2): agenten ringer ut, ingen inngående porter, flåtestyring for maritime selskaper.
4. Én binær, 30 sekunders installasjon.
5. Mobil-først med tastelinje og passkeys: «Termius for nett der SSH ikke virker».

Konklusjon: Markedet er lite men konkret og underbetjent. Teknisk risiko er lav; kommersiell risiko er at gratis alternativer (ttyd + Caddy) er «godt nok» for teknisk sterke brukere. Inntekten ligger derfor i relay/flåte for bedrifter, ikke i enkeltbrukere (se 09).
