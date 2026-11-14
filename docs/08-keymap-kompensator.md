# 08 – Keymap-kompensator

Løser tegnfeil i VNC-konsoller **før** agenten er installert. Logikken ligger i `packages/tp_protocol/lib/src/keymap/` (ren Dart) og brukes av bootstrap-siden i klienten. Siden fungerer også helt offline (kan lagres som én HTML-fil).

## Hvorfor tegn blir feil

noVNC/VNC sender enten *keysyms* (tegnet) eller *fysiske scancodes* (QEMU extended key events). Med scancodes tolker serverens konsoll-keymap den fysiske tasten. Har brukeren norsk tastatur og serveren `us`-keymap, blir f.eks. Shift+. (`:` på norsk) til `>` på US. Det er en **deterministisk tastaturmapping**, ikke tilfeldig støy – og kan derfor inverteres.

## Tre nivåer av løsning (siden foreslår i denne rekkefølgen)

1. **Fiks konsollen:** foreslå `loadkeys no` / `loadkeys us` (kun bokstaver og mellomrom – går alltid gjennom). Siden velger riktig layout ut fra kalibreringen.
2. **Tegnsikker installasjon:** generer installasjonskommando som kun bruker tegn kalibreringen har bekreftet (se 06, rute C).
3. **Invers oversettelse:** for vilkårlig kommando, beregn hva brukeren må *taste* for at riktige tegn skal komme frem.

## Kalibrering

1. Siden viser en testlinje med alle relevante tegn, gruppert og nummerert:
   ```
   1: | 2: : 3: ; 4: > 5: < 6: ( 7: ) 8: $ 9: / 10: - 11: = 12: " 13: ' 14: ~ 15: & 16: * 17: [ 18: ] 19: { 20: } 21: \ 22: @ 23: # 24: _ 25: + 26: ? 27: !
   ```
2. Brukeren skriver **bare tegnene** (uten numre/mellomrom) i VNC-konsollen etter `echo ` – eller bare taster dem i konsollen uten Enter – og leser av hva som faktisk vises.
3. Brukeren taster det som ble vist inn i et felt på siden (lokalt i nettleseren, med fungerende tastatur). Siden kan alternativt ta et skjermbilde-lim-inn og la brukeren klikke tegn (v2).
4. Kompensatoren sammenligner forventet og observert, og:
   - **Gjenkjenner kjente layout-par** (ved å sammenligne mot innebygde tabeller: `no`, `se`, `dk`, `de`, `fr`, `uk`, `us`) → konkluderer f.eks. «klient = no, konsoll = us» → foreslår `loadkeys no`.
   - Ellers bygger den en **direkte mappingtabell** `tastet → vist` fra observasjonene.

Hvis et tegn forsvinner helt (vises ikke), markeres det som *utilgjengelig*.

## Datamodell

```dart
/// What the user physically types (as seen by their own OS) → what appears in console.
final class KeymapProfile {
  final String name;                 // "no→us", "custom-2026-11-14"
  final Map<String, String> typedToShown;
  final Set<String> unavailable;
  final String? suggestedLoadkeys;   // "no"
}

final class EncodeResult {
  final String toType;               // det brukeren skal taste
  final List<String> impossible;     // tegn som ikke kan produseres
  final List<String> warnings;
}

EncodeResult encode(String desired, KeymapProfile p);
```

`encode` bruker den inverse tabellen `shown → typed`. Hvis flere tastinger gir samme tegn, velg den som selv er «trygg» (identitet foretrekkes).

## Alternativer når et tegn er umulig

Kompensatoren foreslår omskrivinger automatisk:

| Mangler | Omskriving |
|---|---|
| `\|` (pipe) | Skriv til fil og kjør i to steg: `wget X` → `sh index.html` |
| `>` | `tee fil` (krever `\|`) eller bruk programmets `-o`/`-O`-flagg |
| `$` | Unngå variabler; skriv ut verdier |
| `/` | `cd` i flere steg er ikke mulig uten `/` → bruk `loadkeys` eller relative stier fra `~` |
| `-` | Velg kommandoer uten flagg (`wget URL` lagrer som `index.html`) |

## Lime inn i VNC

Mange VNC-klienter (noVNC «Clipboard»-panel, Hetzner «Paste») sender tekst som keysyms, som går gjennom samme feilmapping. Siden genererer derfor også en «lim-inn-versjon» basert på samme profil. Lim-inn testes som eget kalibreringsalternativ, siden oppførselen kan være forskjellig fra tasting.

## Grensesnitt på siden

```
[1 Kalibrer] → [2 Resultat: «Konsollen bruker US-oppsett. Skriv: loadkeys no»]
             → [3 Installer: «wget tpinst.com» + «sh index.html»]
             → [4 Avansert: skriv ønsket kommando → vis hva du skal taste, tegn for tegn med farge]
```

Profiler lagres lokalt (localStorage) og kan eksporteres.

## Tester

- Enhetstester for alle innebygde layout-par (begge retninger), rundtur: `shown(encode(x)) == x` for alle mulige x.
- Egenskapsbasert test: tilfeldige strenger over tilgjengelig alfabet.
