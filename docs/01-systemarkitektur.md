# 01 – Systemarkitektur

## Komponentoversikt

```mermaid
flowchart LR
  subgraph Bruker["Bruker (skip/rigg)"]
    B[Nettleser<br/>Terminal Prompter-klient]
  end
  subgraph Nett["Skipsnett / satellitt<br/>(kun 443 stabilt)"]
  end
  subgraph VPS["Server (VPS)"]
    RP[Reverse proxy<br/>Traefik/Caddy/nginx<br/>ELLER innebygd TLS]
    A[tp-agent]
    S1[PTY-sesjon 1<br/>bash/zsh]
    S2[PTY-sesjon n]
    FS[(Filsystem)]
    L[(Auditlogg)]
  end
  B -- HTTPS/WSS 443 --> Nett --> RP --> A
  A --> S1
  A --> S2
  A --> FS
  A --> L
```

## Komponenter

| Komponent | Ansvar | Teknologi |
|---|---|---|
| **tp-agent** | HTTP-server, auth, WS/SSE-transport, PTY-sesjoner, filoverføring, auditlogg, serverer klienten | Dart (AOT, `dart compile exe`), én binær |
| **Nettklient** | Terminalvisning, Prompter-felt, gjenoppkobling, filopplasting, innstillinger | HTML/JS, xterm.js |
| **Bootstrap-side** | Keymap-kalibrering, generering av tegnsikre installasjonskommandoer | Statisk side (hostes på produktdomene + finnes offline i klienten) |
| **Installasjonsskript** | Laster ned riktig binær, oppretter bruker/tjeneste, setter passord, valgfritt TLS | POSIX sh |
| **Relay (v2)** | Mellomledd så agenten kan ringe ut; flåtestyring; betaling | Dart + Postgres, EU-hostet |

## Driftsmodi for agenten

| Modus | Lytter på | TLS | Bruk |
|---|---|---|---|
| `proxy` (standard) | `127.0.0.1:7681` | Håndteres av eksisterende reverse proxy | Servere med Coolify/Traefik, nginx, Caddy |
| `standalone` | `0.0.0.0:443` | Sertifikatfiler (`SecurityContext`); installer anbefaler heller Caddy foran | Servere uten webserver der Caddy ikke ønskes |
| `relay` (v2) | Ingen inngående | Utgående WSS til relay | Servere bak NAT/brannmur, flåter |

## Hovedflyt: bruke terminalen

```mermaid
sequenceDiagram
  participant K as Klient
  participant A as tp-agent
  participant P as PTY
  K->>A: GET / (HTTPS)
  A-->>K: index.html + js (innebygd)
  K->>A: POST /api/login {passord, totp}
  A-->>K: Set-Cookie: tp_session
  K->>A: WS /api/ws (cookie, Origin)
  A-->>K: hello {sessions[]}
  K->>A: attach {session_id|null, cols, rows, last_seq}
  A->>P: spawn shell (hvis ny)
  A-->>K: attached {session_id, seq}
  A-->>K: replay (scrollback fra last_seq)
  loop bruk
    K->>A: input "ls -la\r"
    A->>P: write
    P-->>A: output bytes
    A-->>K: output {seq, data}
    K->>A: ack {seq} (periodisk)
  end
  Note over K,A: Nettbrudd → klient kobler til igjen med last_seq,<br/>agent spiller av det som mangler
```

## Prinsipper

1. **Sesjonen bor på serveren, ikke i forbindelsen.** En PTY lever videre når klienten forsvinner (konfigurerbar levetid, standard 24 t). Klienten er en «visning» som kan festes og løsnes.
2. **All output nummereres.** Hver output-frame har et monotont `seq`. Agenten holder en ringbuffer (standard 1 MB per sesjon). Gjenoppkobling = «send alt etter seq X».
3. **Klienten eier redigeringen.** I Prompter-modus skrives hele kommandoen lokalt (null latens) og sendes som én enhet. I Raw-modus går tastetrykk direkte (for vim, htop osv.).
4. **Transportuavhengig kjerne.** Sesjonslogikken vet ikke om den snakker med WS eller SSE. Begge implementerer samme `Transport`-grensesnitt.
5. **Én binær, null avhengigheter.** Installasjon skal fungere på en minimal Debian/Ubuntu/Alma uten pakkeinstallasjon.
6. **Feil sikkert.** Uten gyldig konfig/passord starter agenten ikke. Lytter aldri på offentlig port uten TLS.

## Ikke-funksjonelle krav

| Krav | Mål |
|---|---|
| Binærstørrelse | < 15 MB |
| Minne (tomgang / per sesjon) | < 20 MB / < 5 MB + ringbuffer |
| Klientstørrelse (gzip) | < 450 KB inkl. xterm.js og dart2js-output |
| Gjenoppkobling etter brudd | < 3 s etter at nett er tilbake |
| Tåle | 800 ms RTT, 10 % pakketap, 64 kbit/s |
| Installasjon | < 60 s fra kommando til innlogging |
| Mobil | Alle funksjoner brukbare på telefon med én hånd (iOS Safari, Android Chrome, siste 2 versjoner); tastelinje lukker aldri telefonens tastatur |
| Plattform | Linux x64/arm64 med glibc (Alpine via gcompat), `setsid` (util-linux/BusyBox), systemd valgfritt |
