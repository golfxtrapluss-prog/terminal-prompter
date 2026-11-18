# 02 – Serveragenten (tp-agent, Dart)

## Pakkestruktur (`packages/tp_agent`)

```
bin/tp_agent.dart                 main: CommandRunner (package:args), signalhåndtering
lib/src/config/                   TOML + env, validering, standardverdier
lib/src/server/                   HttpServer, enkel router, middleware (hoder, logging, rate limit)
lib/src/auth/                     argon2id, TOTP, sesjonscookies, lockout
lib/src/session/                  SessionManager, Session, RingBuffer
lib/src/pty/                      FFI-binding til libc, PtyProcess, leser-isolate
lib/src/transport/                Transport-grensesnitt, ws_transport.dart, sse_transport.dart
lib/src/files/                    opplasting/nedlasting, chunking, gjenopptak
lib/src/audit/                    append-only JSONL, rotasjon
lib/src/update/                   selfupdate, ed25519-verifisering
lib/src/relay/                    (v2) utgående klient mot relay
lib/src/generated/assets.g.dart   innebygde web-filer (generert)
tool/embed_assets.dart
test/
```

## CLI

```
tp-agent run [--config PATH]            start tjenesten
tp-agent init                           førstegangsoppsett (passord, modus, domene)
tp-agent passwd                         bytt passord
tp-agent totp enable|disable            TOTP (viser otpauth-URI + QR som ASCII i terminal)
tp-agent sessions list|kill ID
tp-agent version
tp-agent selfupdate [--channel stable]  last ned, verifiser ed25519 + SHA-256, bytt atomisk
tp-agent uninstall
```

## Konfigurasjon (`/etc/tp-agent/config.toml`)

```toml
mode = "proxy"                 # proxy | standalone | relay(v2)
listen = "127.0.0.1:7681"
base_path = "/"                # f.eks. "/tp-9f3k2/" for skjult sti (obskurering, ikke sikkerhet)
public_origin = "https://tp.example.com"

[tls]                          # kun standalone
cert_file = "/etc/tp-agent/fullchain.pem"
key_file  = "/etc/tp-agent/privkey.pem"

[auth]
password_hash = "$argon2id$v=19$m=65536,t=3,p=2$..."
totp_secret = ""
session_ttl = "12h"
idle_timeout = "4h"             # innlogging uten aktivitet så lenge utløper
max_failed_logins = 5
lockout = "15m"
state_file = "/var/lib/tp-agent/auth.json"   # passkeys, reservekode-hasher, TOTP-gjenbruksvern (0600)

[shell]
command = "/bin/bash"
args = ["-l"]
env = { TERM = "xterm-256color", LANG = "C.UTF-8" }
workdir = "~"
wrap = "none"                  # none | tmux (sesjoner overlever agent-restart)

[sessions]
max = 8
idle_timeout = "24h"
scrollback_bytes = 1048576

[transport]
heartbeat = "15s"
output_coalesce = "25ms"
compression = true
sse_fallback = true

[files]
enabled = true
max_upload = "2GB"
chunk_size = "256KB"
root = "~"

[fleet]                        # v2, kun relay-modus
fleet_exec = true              # false = avvis alle flerserverjobber
max_concurrent_runs = 4

[update]
url = ""                       # release-URL med SHA256SUMS(.sig); tom = innbakt standard

[audit]
enabled = true
log_input = true
path = "/var/lib/tp-agent/audit.jsonl"
```

## PTY i Dart – design

Dart har ingen innebygd PTY-støtte. Løsningen er en tynn FFI-modul mot libc pluss systemverktøyet `setsid` (util-linux, finnes på alle vanlige distroer; BusyBox har også `setsid -c`).

**Hvorfor ikke `forkpty()` via FFI?** `fork()` i en flertrådet Dart-VM er udefinert/risikabelt (kun async-signal-safe kall i barnet, og Dart-runtime holder låser). Vi unngår fork i egen prosess helt og lar `Process.start` (som bruker trygg posix_spawn/fork+exec internt i VM-en) starte barnet.

### Steg for å starte en sesjon

1. **FFI:** `master = posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC)`, `grantpt(master)`, `unlockpt(master)`, `ptsname_r(master)` → f.eks. `/dev/pts/7`.
2. **Sett størrelse:** `ioctl(master, TIOCSWINSZ, &winsize)`.
3. **Start barn:**
   ```dart
   Process.start('/bin/sh', [
     '-c',
     'exec setsid -c "\$0" "\$@" <"\$TP_PTS" >"\$TP_PTS" 2>&1',
     shellCommand, ...shellArgs,
   ], environment: {...env, 'TP_PTS': ptsPath}, workingDirectory: workdir,
      mode: ProcessStartMode.normal);   // IKKE detached – se punkt 4
   ```
   `sh` åpner slave-enheten som stdin/stdout/stderr, `setsid -c` lager ny sesjon og gjør stdin (PTY-en) til kontrollerende terminal, deretter `exec` av skallet. Resultat: korrekt jobbkontroll, Ctrl-C, `sudo`-prompts, vim osv.
4. **PID og modus:** Bruk `ProcessStartMode.normal`. I `detached`-modus kaller Dart selv `setsid()`, så `sh` blir sesjonsleder og får slave-PTY-en som kontrollerende terminal ved `open`, og util-linux `setsid` må forke → feil pid og `TIOCSCTTY` feiler. I `normal`-modus er `sh` ikke gruppeleder, `setsid` forker ikke, og kjeden sh → setsid → bash beholder samme pid. `Process.exitCode` gir dermed avslutningskode og reaping gratis. Dart-pipene for stdio blir ubrukte (alt er omdirigert til PTY) – lukk `stdin`-sinken og drener `stdout/stderr` (tomme). Verifiser pid-bevaring i test (`/proc/<pid>/stat` → sid == pid).
5. **Lesing:** En `Isolate` per sesjon kjører en blokkerende `read(master, buf, 32768)`-løkke via FFI og sender `TransferableTypedData` til hovedisolatet via `SendPort`. `read` returnerer 0/`EIO` når barnet avsluttes → isolatet sender `exit`.
6. **Skriving:** `write(master, ...)` via FFI fra hovedisolatet (små skrivinger, ikke-blokkerende nok i praksis; for store innlim deles i 4 KB-biter med `await Future.delayed(Duration.zero)` mellom).
7. **Resize:** `ioctl(TIOCSWINSZ)` + kernel sender SIGWINCH til forgrunnsgruppen automatisk.
8. **Signaler:** Skriv kontrolltegn (`\x03`, `\x1a`, `\x04`) til master for INT/TSTP/EOF. For KILL/TERM: `Process.killPid(pid, ProcessSignal.sigterm)` + `kill(-pgid)` via FFI for hele gruppen.
9. **Avslutning:** `Process.exitCode` fullføres → lukk master-fd, stopp leser-isolate. Ved agent-stopp drepes alle sesjonsgrupper eksplisitt; systemd `KillMode=control-group` er sikkerhetsnett.

`ioctl` er variadisk i C – bind den som `int ioctl(int, unsigned long, Pointer<WinSize>)` med `@Native`/`lookupFunction` og test på både x64 og arm64 (konstantverdien `TIOCSWINSZ = 0x5414` er lik på begge for Linux).

**Alternativ vurdert:** pub-pakken `pty` (FFI + forkpty). Avvist pga. fork-risikoen og lav vedlikeholdsgrad, men kan brukes som referanse.

**tmux-modus (`wrap = "tmux"`):** skallet startes som `tmux new-session -A -s tp-<id>`. Da overlever sesjonene oppgradering/restart av agenten; agenten gjenoppdager dem med `tmux ls` ved oppstart.

## Sesjonsmodell

```dart
final class Session {
  final String id;            // 128-bit tilfeldig (Random.secure), base32
  String name;
  final DateTime created;
  DateTime lastSeen;
  final PtyProcess pty;
  final RingBuffer buffer;    // bytes med seq
  int seq;                    // neste byte-seq (Dart int er 64-bit på native)
  final Map<int, Subscriber> subscribers;
  int cols, rows;
  ExitInfo? exited;
}
```

- **Flere klienter** kan vise samme sesjon. Siste som sendte input er «primær» for størrelse.
- **Treg abonnent:** sendekø > 4 MB → koble fra; klienten gjenopptar fra seq.
- **Avsluttet prosess:** sesjon markeres `exited`, beholdes 1 t, ryddes.

## Ringbuffer

- Fast kapasitet (`Uint8List`), sirkulær. `seq` teller **bytes**, så gjenopptak er uavhengig av frame-oppdeling.
- `readFrom(seq)` → `(data, truncatedFrom?)`.

## Filoverføring

- `POST /api/files/upload` med `Upload-Id`, `Upload-Offset`; `HEAD` gir mottatt offset (gjenopptak).
- `GET /api/files/download?path=` med `Range`.
- `GET /api/files/list?path=`.
- Stier: `path.normalize` + `File.resolveSymbolicLinks` + prefiks-sjekk mot `files.root`.
- Skriv til `*.part`, `flush(flush: true)`, `rename`.
- Filer skrives som agentens bruker; ved behov for annen eier gjør brukeren `sudo mv` i terminalen.

## HTTP-endepunkter

| Metode | Sti | Auth | Formål |
|---|---|---|---|
| GET | `/`, `/assets/*` | nei | Klient (innebygd, gzip, ETag) |
| GET | `/bootstrap` | nei | Keymap-kompensator (kan deaktiveres) |
| POST | `/api/login` | nei (rate limit) | `{password, totp?}` eller `{backup_code}` → cookies `tp_session` (HttpOnly) og `tp_csrf` |
| GET | `/api/auth/methods` | nei | `{totp, passkeys}` så innloggingssiden vet hvilke felt som trengs |
| POST | `/api/auth/passkey/login/options` | nei | WebAuthn-utfordring for innlogging |
| POST | `/api/auth/passkey/login` | nei (rate limit) | Verifiserer passkey-signatur → cookies |
| POST | `/api/logout` | ja | Avslutter denne innloggingen og lukker dens WebSockets (kode 4401) |
| POST | `/api/logout-all` | ja | Avslutter alle innlogginger |
| POST | `/api/auth/logins/revoke` | ja | `{id}`: logg ut én annen enhet |
| POST | `/api/auth/passkey/register/options` | ja | WebAuthn-utfordring for registrering |
| POST | `/api/auth/passkey/register` | ja | Lagrer ny passkey |
| POST | `/api/auth/passkey/remove` | ja | `{id}` |
| POST | `/api/auth/backup-codes` | ja | Lager 10 nye reservekoder (vises én gang), gamle slutter å virke |
| GET | `/api/me` | ja | Versjon, innlogginger, passkeys, reservekoder igjen, TOTP på/av |
| GET | `/api/ws` | ja | WebSocket (`WebSocketTransformer.upgrade`, `CompressionOptions`) |
| GET | `/api/sse` | ja | Fallback-utstrøm (`text/event-stream`), første hendelse `sse_open` med strøm-ID |
| POST | `/api/sse/send?stream=ID` | ja + CSRF | Fallback-inn: JSON-liste med kontrollmeldinger og `{"t":"in",…}` |
| GET | `/api/files/list?path=` | ja | Mappeinnhold (mapper først), `chunk_size`, `max_upload` |
| GET/HEAD | `/api/files/download?path=` | ja | Nedlasting med `Range` (206), `Content-Disposition` |
| POST | `/api/files/upload` | ja + CSRF | `{dir, name, size, overwrite?}` → `{id, offset}`; samme mål og størrelse gjenopptar |
| POST | `/api/files/upload/ID` | ja + CSRF | Rå bytes med `Upload-Offset`; svar `{offset, done}`; feil offset → 409 med riktig `Upload-Offset` |
| HEAD | `/api/files/upload/ID` | ja | `Upload-Offset` = mottatte bytes |
| DELETE | `/api/files/upload/ID` | ja + CSRF | Avbryt og slett `.part` |
| GET | `/healthz` | nei | `ok` |

## Kjøring av Dart-binæren

- `dart compile exe` gir en AOT-binær som er dynamisk lenket mot glibc. Fungerer på Debian/Ubuntu/RHEL-familien. **Alpine** krever `gcompat` – installer sjekker og installerer det.
- Kryss-kompilering: `dart compile exe --target-os linux --target-arch arm64` (Dart ≥ 3.8).
- Forventet størrelse 8–15 MB inkl. innebygde web-filer.

## Systemd-enhet

```ini
[Unit]
Description=Terminal Prompter agent
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/tp-agent run --config /etc/tp-agent/config.toml
User=tp
Restart=always
RestartSec=2
KillMode=control-group
ProtectSystem=full
ReadWritePaths=/var/lib/tp-agent /home/tp
AmbientCapabilities=CAP_NET_BIND_SERVICE   # kun standalone på 443

[Install]
WantedBy=multi-user.target
```

En terminal *skal* kunne administrere hele serveren. Brukeren `tp` får derfor sudo (valg i installasjon). Herdingen begrenser agentprosessen, ikke det brukeren bevisst gjør i skallet.
