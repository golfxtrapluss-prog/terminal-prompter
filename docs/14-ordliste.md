# 14 – Ordliste

| Begrep | Forklaring |
|---|---|
| **Agent** | `tp-agent`, programmet som kjører på serveren |
| **PTY** | Pseudo-terminal: kjernepar (master/slave) som lar et program tro det snakker med en ekte terminal |
| **Master-fd** | Agentens ende av PTY-en; det den leser output fra og skriver input til |
| **Sesjon** | Ett skall i én PTY, identifisert med ID; lever uavhengig av nettforbindelsen |
| **Attach/detach** | Feste/løsne en klientvisning til/fra en sesjon |
| **seq** | Byte-teller for output; brukes til gjenopptak |
| **Ringbuffer** | Fast stor minnebuffer med siste output per sesjon |
| **client_msg_id** | Klientens løpenummer på input; gjør resend trygt (idempotens) |
| **Prompter-modus** | Lokal redigering av hele kommandoen før sending |
| **Raw-modus** | Hvert tastetrykk sendes direkte (for fullskjermprogrammer) |
| **Alternate screen** | Skjermmodus fullskjermprogrammer bruker (`ESC[?1049h`) |
| **Bracketed paste** | Skallmodus som markerer innlimt tekst så den ikke kjøres linje for linje |
| **SSE** | Server-Sent Events: enveis HTTP-strøm, brukt som fallback når WebSocket er blokkert |
| **Keymap / loadkeys** | Konsollens tastaturoppsett / kommando som bytter det |
| **Keysym / scancode** | VNC-tastehendelser: tegnet vs. fysisk tast |
| **Bootstrap** | Første installasjon av agenten, ofte via VNC-konsoll |
| **Relay** | Skytjeneste agent og nettleser begge kobler ut til (v2) |
| **AOT** | Ahead-of-time-kompilering (`dart compile exe`) |
| **dart2js** | Dart → JavaScript-kompilator (`dart compile js`) |
| **FFI** | Foreign Function Interface (`dart:ffi`) – kall til C-funksjoner i libc |
| **Flerserverkjøring / jobb / kjøring** | Én kommando sendt til mange servere (jobb) og utførelsen på hver enkelt server (kjøring), se doc 15 |
| **Kanari** | Kjør på én server først og godkjenn før resten |
| **Tastelinje** | Rad med spesialtegn og terminaltaster over telefonens tastatur (doc 16) |
| **PWA** | Progressive Web App: nettside som kan installeres på hjemskjermen som en app |
| **Passkey / WebAuthn** | Innlogging med fingeravtrykk/ansikt/nøkkel i stedet for passord |
| **SNI** | Server Name Indication: vertsnavnet i starten av et TLS-håndtrykk, som relay ruter på uten å dekryptere |
| **TLS-gjennomstrømming** | Relay videresender kryptert trafikk uten å kunne lese den |
| **CSR** | Sertifikatforespørsel laget med agentens egen nøkkel |
| **Reservekoder** | Engangskoder for innlogging når passkey-enheten er tapt |
| **Reisepass** | Tidsbegrenset relay-tilgang uten abonnement |
| **Isolate** | Darts tråd-ekvivalent med egen minnehaug; brukes for blokkerende PTY-lesing |
