# 06 – Bootstrap og installasjon

Utfordringen: agenten må installeres **før** man har en fungerende terminal. Brukeren har kanskje bare en VNC-konsoll som ødelegger tegn. Produktet må derfor tilby flere veier inn, rangert fra enklest til mest robust.

## Rute A – Ingen VNC i det hele tatt (anbefalt når mulig)

| Situasjon | Metode |
|---|---|
| Server med Coolify | Deploy Docker-imaget `ghcr.io/<org>/tp-agent` som en tjeneste via Coolify-UI (HTTPS). Coolify/Traefik gir TLS og domene. Krever `privileged` / host-PID-modus eller at skallet kjøres via `nsenter` inn i host – se under. |
| Ny server | Lim inn cloud-init (`user_data`) ved opprettelse hos Hetzner/DO/AWS. Siden genererer cloud-init-YAML ferdig utfylt. |
| Annet fungerende webpanel (Webmin, Plesk, cPanel-terminal) | Lim inn én installasjonslinje der |

**Docker-variant:** Image inneholder agenten; container startes med `--pid=host --privileged` og `shell.command = "nsenter -t 1 -m -u -i -n -p -- /bin/bash -l"`, slik at terminalen faktisk er på verten, ikke i containeren. Dokumenter tydelig at dette gir full vertstilgang (det er meningen).

## Rute B – VNC-konsoll, fikse tastaturet først

De fleste tegnfeil skyldes at konsollens keymap ikke matcher brukerens fysiske tastatur. To kommandoer som **bare inneholder bokstaver og mellomrom** (og derfor kommer trygt gjennom) løser ofte alt:

```
loadkeys no
```

(eller `loadkeys us` – bootstrap-siden finner riktig variant via kalibrering, se 08). Alternativt bytt tastaturoppsett lokalt på PC-en til US mens VNC-vinduet er aktivt.

Deretter fungerer standard installasjonskommando.

## Rute C – VNC-konsoll, tegnsikker installasjon

Når keymap ikke kan fikses: installasjonskommando som unngår problemtegn helt.

Domenet for installasjon velges slik at hele kommandoen kun består av **små bokstaver, siffer, mellomrom og punktum**:

```
wget tpinst.com
sh index.html
```

- `wget` uten skjema bruker http og lagrer som `index.html`. Serveren på `tpinst.com` svarer på `/` (http) med en **liten** sh-stub (ikke HTML) som:
  1. henter det egentlige installasjonsskriptet over **https**,
  2. verifiserer SHA-256 mot verdi innbakt i stuben,
  3. kjører det.
- Stuben over http er en svakhet (MITM kan bytte den). Avbøt: stuben er så kort at brukeren kan lese den i VNC-konsollen før kjøring (`cat index.html` – også tegnsikker), og bootstrap-siden viser forventet innhold side om side.
- Fallback hvis `wget` mangler: `curl tpinst.com ` krever `-o`/`>`; derfor tilbys også `python3 -m` -varianten **kun** hvis kalibreringen viser at `-` fungerer. Bootstrap-siden velger automatisk den varianten som kun bruker tegn kalibreringen har bekreftet.

Brukeren må eie/kjøpe et kort domene uten bindestrek (f.eks. `tpinst.com`, `tprompt.io` → `.` er nødvendig; sjekk at `.` er trygt – det er det på alle vanlige layouter, men kalibrering bekrefter).

## Rute D – Keymap-kompensator

Hvis selv kalibreringen viser at mange tegn er feil og `loadkeys` ikke er tilgjengelig: kompensatoren (doc 08) oversetter ønsket kommando til det brukeren må **taste** for at riktige tegn skal komme frem. Siste utvei, men fungerer for vilkårlige kommandoer.

## Installasjonsskriptet (`install.sh`)

Krav: POSIX sh, ingen bash-ismer, kjører på Debian/Ubuntu/Alma/Rocky/Alpine.

Steg:

1. Oppdag arkitektur (`uname -m` → amd64/arm64) og init-system.
2. Last ned `tp-agent-linux-<arch>` og `SHA256SUMS` over HTTPS fra GitHub Releases (eller eget CDN) og verifiser med `sha256sum -c`. Full ed25519-signaturverifisering gjøres av agenten selv (`tp-agent verify` / `selfupdate`) – skriptet kan ikke forutsette at minisign/openssl finnes.
2b. Sjekk forutsetninger for Dart-binæren: glibc (på Alpine: `apk add gcompat`) og `setsid` (util-linux eller BusyBox ≥ 1.30 med `-c`). Mangler noe → installer det eller avbryt med tydelig melding.
3. Opprett systembruker `tp`, kataloger `/etc/tp-agent`, `/var/lib/tp-agent`.
4. Spør (eller les flagg): modus `proxy`/`standalone`, domene, om `tp` skal få sudo.
5. Oppdag eksisterende webserver: Traefik/Coolify (docker-container `coolify-proxy`), nginx, Caddy → foreslå `proxy`-modus og skriv ferdig konfig-snutt (Traefik dynamic file / nginx `location` / Caddyfile) – **spør før den skrives**.
6. Generer passord, skriv config, installer systemd-enhet, start.
7. Skriv ut: URL, passord (én gang), og «test nå».

Flagg for ikke-interaktiv bruk: `--mode`, `--domain`, `--email`, `--password-file`, `--sudo`, `--yes`.

## Automatisk HTTPS og relay

- `install.sh --domain tp.example.com`: sjekker DNS, installerer Caddy hvis ingen webserver finnes, tester HTTPS utenfra (rute 2, doc 17).
- `install.sh --link TPLK-XXXX-XXXX`: kobler serveren til relay uten domene (rute 1, v1.5, doc 17).
- Uten flagg: interaktiv veiviser som spør hvilken rute.

## Reverse proxy-snutter (genereres av installer)

**Caddy:**
```
tp.example.com {
    reverse_proxy 127.0.0.1:7681
}
```

**nginx:**
```nginx
location / {
    proxy_pass http://127.0.0.1:7681;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_read_timeout 3600s;
    proxy_buffering off;          # viktig for SSE
}
```

**Traefik (Coolify), dynamic config:**
```yaml
http:
  routers:
    tp:
      rule: Host(`tp.example.com`)
      entryPoints: [https]
      service: tp
      tls: { certResolver: letsencrypt }
  services:
    tp:
      loadBalancer:
        servers: [{ url: "http://host.docker.internal:7681" }]
```
(Agenten må da lytte på docker-bridge-IP, f.eks. `172.17.0.1:7681`, ikke bare 127.0.0.1 – installer håndterer dette.)

## Avinstallasjon

`tp-agent uninstall` fjerner tjeneste, binær, konfig (spør om data/auditlogg skal beholdes).
