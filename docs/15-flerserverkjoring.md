# 15 – Flerserverkjøring (v2)

Kjør samme kommando på mange servere samtidig og se resultatene samlet. Bygger på relay (doc 09) og kommer i **v2.0**, milepæl M7.5. Finnes ikke i v1.

## Hvorfor dette passer skipsbruk spesielt godt

Jobben eies av **relay**, ikke av nettleseren. Brukeren sender jobben, og relay sørger for at den kjøres på alle servere og tar vare på resultatene, selv om skipsnettet faller ut rett etter at du trykket «kjør». Når du kobler til igjen, ligger resultatene klare. Ansible og pssh krever at din egen maskin holder SSH-forbindelsen til alle servere gjennom hele jobben, og det fungerer ikke om bord.

## Begreper

| Begrep | Forklaring |
|---|---|
| **Mål (target)** | En registrert agent/server |
| **Merkelapp (tag)** | Fritt valgt etikett på mål: `prod`, `skip-a`, `coolify`, `eu` |
| **Gruppe** | Lagret utvalg, f.eks. «alle prod-servere» = `tag:prod AND NOT tag:db` |
| **Jobb** | Én kommando sendt til et utvalg mål, med ID, innstillinger og resultater |
| **Kjøring** | Jobbens utførelse på ett bestemt mål |

## Kjøremoduser

| Modus | Oppførsel | Standard for |
|---|---|---|
| **Kanari** (standard) | Kjør på 1 mål først → vis resultat → brukeren godkjenner resten | Alle jobber mot > 3 mål |
| **Parallell** | Alle samtidig, maks N i gang (standard 10) | Lesekommandoer (`df -h`, `docker ps`) |
| **Rullerende** | Grupper på N, neste gruppe starter når forrige er ferdig og vellykket | Oppdateringer, restart av tjenester |
| **Sekvensiell** | Én og én | Følsomme operasjoner |

Alle moduser har:
- **Stopp ved feil:** terskel (f.eks. stopp hvis > 1 mål feiler, eller ved første feil).
- **Tidsavbrudd per kjøring** (standard 10 min) og for hele jobben.
- **Avbryt-knapp:** sender TERM og deretter KILL til alle pågående kjøringer.

## Mål som er frakoblet

| Innstilling | Oppførsel |
|---|---|
| `skip` (standard) | Markeres «ikke tilgjengelig» i resultatet |
| `queue` | Relay holder kjøringen og starter den når agenten kobler seg til, innen en utløpstid (standard 1 t, maks 24 t) |

## Hvordan kommandoen kjøres på agenten

- **Ikke** i brukerens interaktive sesjon. Hver kjøring får sitt eget ikke-interaktive skall: `bash -lc '<kommando>'` med egen PTY (så programmer som krever terminal fungerer), `stdin` lukket.
- Miljø: samme bruker og innstillinger som vanlige sesjoner (`[shell]` i config).
- Interaktive kommandoer (`vim`, `sudo` med passord) støttes ikke, og agenten avbryter dem ved tidsavbrudd. `sudo` forutsetter NOPASSWD eller at jobben kjøres som root (Fleet-policy).
- Output lagres i agenten (ringbuffer per kjøring, maks 2 MB) og strømmes til relay, som lagrer opptil 10 MB per kjøring i 30 dager (Fleet: konfigurerbart).

## Resultatvisning

```
Jobb #482  «docker ps --format '{{.Names}}'»   12 mål  ·  rullerende 3  ·  ferdig 11 ✓  1 ✗

┌ Gruppert etter identisk output ──────────────────────────────┐
│ 9 servere   coolify, coolify-proxy, coolify-db               │
│ 2 servere   coolify, coolify-proxy                  [vis diff]│
│ 1 server    ✗ exit 127: docker: command not found  web-old-3 │
└──────────────────────────────────────────────────────────────┘
[Tabell per server] [Side om side] [Eksporter CSV/JSON] [Kjør på nytt på feilede]
```

- **Gruppering av like svar** er hovedvisningen. Med 50 servere er avvikene det interessante.
- Status per mål: venter / kjører / ✓ / ✗ (exit-kode) / tidsavbrudd / frakoblet / avbrutt.
- «Kjør på nytt på feilede» lager en ny jobb med samme kommando mot bare de feilede målene.

## Sikkerhet

Én feil kommando treffer alle servere. Derfor:

1. **Forhåndsvisning av mål:** før kjøring vises nøyaktig liste over servere som blir truffet.
2. **Bekreftelse som skaleres:** ≤ 3 mål gir vanlig knapp. > 3 mål krever at antallet skrives inn («skriv 24 for å bekrefte»).
3. **Farlige mønstre** (samme liste som Prompter, doc 03) gjør kanari-modus og «stopp ved første feil» obligatorisk.
4. **Tilgang (Fleet):** roller avgjør hvilke grupper en bruker kan kjøre mot. Policy kan kreve **godkjenning fra en annen person** for jobber mot `tag:prod` eller med farlige mønstre.
5. **Revisjon:** hver jobb logges med bruker, kommando, mål, modus, godkjenner og resultat per mål. Logges både i relay og i hver agent.
6. **E2E-kryptering (v2.1):** relay kan ikke lese kommando eller output. Konsekvens: gruppering av like svar skjer da i nettleseren, ikke i relay.
7. **Agent-side kontroll:** agenten kan settes til `fleet_exec = false` og avviser da alle flerserverjobber, uavhengig av hva relay sier.

## Protokoll (tillegg til doc 04, kun relay-modus)

Relay → agent:

| `t` | Felter |
|---|---|
| `exec_start` | `job`, `run`, `cmd`, `timeout_s`, `env?`, `cols`, `rows` |
| `exec_cancel` | `run`, `sig` (`TERM`/`KILL`) |

Agent → relay:

| `t` | Felter |
|---|---|
| `exec_accepted` | `run` |
| `exec_rejected` | `run`, `reason` (`disabled`, `busy`, `policy`) |
| `exec_out` | `run`, `seq`, `d` (binærframe type `0x03`) |
| `exec_exit` | `run`, `code`, `signal?`, `duration_ms`, `truncated` |

`run`-ID gjør utførelsen idempotent: en agent som får samme `exec_start` to ganger (etter brudd) kjører den bare én gang og svarer med status for den eksisterende kjøringen.

Klient ↔ relay (REST + WS-varsler): `POST /api/jobs`, `GET /api/jobs/{id}`, `POST /api/jobs/{id}/approve|cancel|retry-failed`, WS-strøm `job_update`.

## Datamodell i relay (Postgres)

```
targets(id, account_id, name, tags[], last_seen, agent_version, fleet_exec_enabled)
groups(id, account_id, name, selector)
jobs(id, account_id, user_id, cmd, selector, resolved_targets[], mode, batch_size,
     max_parallel, fail_threshold, timeout_s, offline_policy, status, approved_by, created_at)
runs(id, job_id, target_id, status, exit_code, started_at, ended_at, output_ref, output_bytes)
```

Output lagres i objektlagring (EU), ikke i Postgres.

## Snutter og maler

Lagrede jobber med variabler, f.eks. `docker restart {{tjeneste}}` mot `gruppe:prod`. Fleet: delt bibliotek for teamet. Kan senere planlegges (cron) – det er utenfor v2.0.

## Inntekt

| Nivå | Flerserverkjøring |
|---|---|
| Personal | Ikke inkludert |
| Pro | Inntil 10 mål per jobb, parallell og kanari |
| Fleet | Ubegrenset, alle moduser, roller, godkjenning, revisjonseksport, delte maler |

Flerserverkjøring er hovedgrunnen til å oppgradere fra Personal til Pro/Fleet, og bør vises i demo og på prissiden.
