# Geschwindigkeit — Backlog

Analog zu `docs/implizite-informationen.md`, aber für Laufzeit statt
Kompressionsrate: ein Katalog aller geprüften und offenen Hebel. Status:
✓ = genutzt, ○ = offen/ungeprüft. Betrifft NUR den Coder/die Modell-
Implementierung — der Markov-/Permutations-/Geburtstagsparadox-Kern ist
hiervon nicht berührt (Geschwindigkeit ist reine Umsetzungsfrage).

## A. Bereits genutzt

1. ✓ Blockparallelität über Threads (`--threads`/`-T`, TaskGroup) — nbcm/nbcmb/nbcmbf
2. ✓ safe/unsafe Dual: `UnsafeMutablePointer`-Tabellen statt Array-Bounds-Checks (`--unsafe`)
3. ✓ GPU-Suffix-Sortierung via MPSGraph-ArgSort (`--gpu`) — nur nbcm-Linie (braucht BWT/Suffix-Array), für ncmm wirkungslos
16. ✓ `InlineArray` (Swift 6.3, SE-0453) für kleine, zur Compile-Zeit feste Puffer — umgesetzt 2026-07-06, siehe Abschnitt C unten. Nicht kompiliert/getestet (kein Swift-Toolchain-Zugriff hier) — User muss `swift test` + Selbsttests laufen lassen.
21. ✓ `@inline(__always)` konsistent auf allen heißen Pro-Bit/Pro-Nibble-Methoden — umgesetzt 2026-07-06 als Nebenprodukt von Nr. 11 (User-Nachfrage: "nutzen wir eigentlich @inline(__always) Empfehlungen?"). Vorher inkonsistent: BEN_NBCM.swift/BEN_MEC.swift hatten es bereits auf `predict`/`update`, BEN_CM.swift/BEN_CME.swift NICHT — dort war nur `squash`/`stretch` (Ein-Zeilen-Tabellen-Lookup) und bei BEN_CME teilweise die unsafe-Variante annotiert. Jetzt einheitlich auf `predict`, `update`, `pushNibble`, `matchUpdate`, `beginNibble` in beiden Klassen (safe + unsafe) von BEN_CM.swift/BEN_CME.swift.

## B. Übliche Techniken, noch nicht geprüft

4. ○ SIMD für den Mixer-Dot-Product (`SIMD4<Int32>`/`SIMD8<Int32>` statt Skalar-Schleife über 9–12 Modelle). Vermutlich kleiner Gewinn: die Schleife ist kurz, der wahre Flaschenhals sind eher die Hash-Tabellenzugriffe (Cache-Misses), nicht die Arithmetik — vor Umsetzung profilen
5. ○ Software-Prefetch für die großen Hash-Tabellen (o3/o4/o6/o8/o12/wd/sp/mm) — Standardtechnik aus der paq-Familie, versteckt Speicherlatenz hinter anderer Arbeit
6. ○ Array-of-Structs statt Struct-of-Arrays je Hash-Slot (prob+checksum+counter in einem zusammenhängenden Eintrag statt drei getrennten Arrays `o8p`/`o8c`/`o8k`) — ein Cache-Miss statt bis zu drei pro Lookup
7. ○ Branchless Prüfsummen-Reset (Maske/`select` statt `if o8k[h8] != k8 { … }`) — unvorhersagbarer Sprung pro Tabellenzugriff, Nutzen vermutlich klein gegen den Cache-Miss selbst
8. ○ Huge-Page-/page-aligned Allokation der großen Tabellen (2^24–2^25 Einträge, ~700 MB bei ncmme) — weniger TLB-Misses
9. ○ Loop-Unrolling der 4-Bit-Baumtraversal (Tiefe 0..3 ist zur Compile-Zeit bekannt) — erst prüfen, ob der Compiler das bei Release-Optimierung nicht ohnehin schon tut
10. ○ Carryless-Range-Coder (Subbotin-Stil) statt Cache/Carry-Propagation (`shiftLow`, `while cacheSize > 1`) — eliminiert eine seltene, aber vorhandene Schleife

## C. Konkreter Quick-Win (beim Code-Review gefunden, 2026-07-06)

11. ✓ **Hash-Vorberechnung pro Nibble statt pro Bit — UMGESETZT
    (2026-07-06).** `predict(node:depth:)` in `BEN_CM.swift`/
    `BEN_CME.swift` berechnete `f3/f4/f6/f8/f12` (mehrere 32/64-Bit-
    Multiplikationen) bei JEDEM der 4 Bit-Aufrufe eines Nibbles neu — der
    `hist`/`isHigh`/`wordHash`/`buf.count`-abhängige Anteil ist aber über
    alle 4 Aufrufe eines Nibbles identisch, nur der kleine `node`-Term
    ändert sich. Neue Methode `beginNibble()` (in CMModel, CMEModel und
    CMEModelU — safe UND unsafe) berechnet diesen Anteil einmal je Nibble
    in Felder `baseF3/baseF4/baseF6/baseFw/baseFs` (bei BEN_CME zusätzlich
    `baseF8/baseF12`); `predict()` addiert nur noch den `node`-Term.
    Aufgerufen in allen 6 Encoder-/Decoder-Schleifen (BEN_CM: 2, BEN_CME
    safe: 2, BEN_CME unsafe: 2) direkt vor der 4-Bit-Baumtraversal. Spart
    3 von 4 Multiplikationsdurchläufen für fünf (bzw. sieben bei ncmme)
    Hashes — reine Faktorisierung, bitidentisch, durch die bestehenden
    Bitidentitäts-/Selbsttest gegen Regressionen abgesichert. Nicht
    kompiliert (kein Swift-Toolchain-Zugriff hier) — User muss
    `swift test` + `ben --selftest --algorithm ncmm` und `ncmme` laufen
    lassen, danach Vorher/Nachher-Zeitvergleich auf enwik8/silesia.

16. ✓ **`InlineArray` statt größenveränderbarem `Array` für kleine, zur
    Compile-Zeit feste Puffer (User-Frage, Swift 6.3, 2026-07-06) —
    UMGESETZT.** `Package.swift` steht auf `swift-tools-version: 6.3` —
    SE-0453 ohne Toolchain-Wechsel nutzbar. `InlineArray` liegt inline im
    Speicher der Klasseninstanz (kein separates Heap-Objekt, kein ARC,
    keine COW-Prüfung), verhält sich beim Zugriff wie `Array`
    (Laufzeit-Index `x[i]` funktioniert normal) — das unterscheidet es
    entscheidend von einem Tupel, dessen `.0`/`.1`-Zugriff keine
    Laufzeitindizierung erlaubt (unser Mixer-Loop
    `for i in 0..<kNModels { dot += st[i] * wx[mctx+i] }` braucht genau
    das, Tupel wären hier also die falsche Wahl).

    **Umgesetzt in:** BEN_CM.swift/BEN_CME.swift (`kRate`, `Sigmoid.points/
    squash/stretch`, `o0p/o0c`, `o1p/o1c`, `mmp/mmc`, `wx`, `st`, `apm`,
    `apm2`, bei BEN_CME zusätzlich `alp/alc`); BEN_NBCM.swift
    (`NBCMSigmoid.points/squash/stretch`, `fast`, `slow`, `w`, `mtf`,
    `apm`); BEN_MEC.swift (`mtf`, `probRepeat`, `probRun`, `probRepChain`,
    `probNewChain`); NibbleBWT.swift (`countPerValue`, `firstOccurrence`
    in `inverseTransform`). Bitidentisch per Konstruktion (reine
    Speicherdarstellungsänderung, keine Logikänderung).

    **Bewusst NICHT umgestellt, mit Begründung:**
    - Die großen Hash-Tabellen (o2 mit ~2 Mio. Einträgen, o3–o12/wd/sp/mm
      mit 2^22–2^25 Einträgen) — das ist kein Zielfeld für `InlineArray`
      (gedacht für kleine, stack-taugliche Puffer, nicht Hunderte MB pro
      Instanz); zusätzliches Risiko, da eine so große Größe als
      Compile-Zeit-Generic-Parameter unüblich und ohne Compiler hier nicht
      verifizierbar ist.
    - `rank` in `NibbleBWT.inverseTransform` und die Histogramme in
      `NibblePlanarDeltaFilter.chooseStride` — beide laufen durch
      `withUnsafeMutableBufferPointer`, eine API, die `InlineArray` laut
      SE-0453 noch NICHT anbietet (als „Span APIs" explizit auf später
      verschoben). Der Bounds-Check-Overhead ist dort durch den
      bestehenden Unsafe-Pfad ohnehin schon eliminiert — kein Verlust.
    - `validStrides` in `NibblePlanarDeltaFilter.swift` (4 Einträge) —
      wird über `.contains(_:)` abgefragt, eine Sequence-Methode, die
      `InlineArray` (noch) nicht unterstützt; für 4 statische Einträge
      lohnt der Umbau nicht.
    - `raw`/`freq`/`cdf` in `BEN_BWT.swift` (Legacy-Algorithmus 0x01,
      nur Dekomprimierungs-Kompatibilität, kein aktiver Kompressionspfad)
      — nutzen `.reduce`/`.map`/`.filter`, ebenfalls Sequence-Methoden;
      zurückgestellt, da nicht performance-kritisch und Umbau-Aufwand
      höher als Nutzen.

    **Wichtige Konsumstellen-Anpassung:** `InlineArray` ist bewusst KEIN
    `Sequence`/`Collection` (SE-0453, Zukunftsrichtung). Jede Stelle, die
    vorher `for x in array { … }` direkt über eines der umgestellten
    Arrays iterierte (die MTF-Kandidatenkette `mtf` in BEN_MEC.swift und
    BEN_NBCM.swift, je zwei Stellen in Encoder und Decoder), wurde auf
    `for idx in array.indices { let x = array[idx]; … }` umgestellt —
    verhält sich identisch (inkl. `continue`/`break`), da `.indices` ein
    normaler `Range<Int>` ist.

    **Best Practice, ab jetzt für neuen Code in diesem Projekt:** kleine,
    zur Compile-Zeit fest dimensionierte Puffer (Sigmoid-/Rate-Tabellen,
    Modell-Slots, feste Kontextgrößen) als `InlineArray<N, T>` deklarieren
    statt `[T](repeating:count:)` — außer wenn (a) die Größe von
    Laufzeitdaten abhängt (Dateigröße, Blockanzahl, Hash-Bit-Konstanten
    im Millionenbereich) oder (b) der Code auf Sequence/Collection-Methoden
    (`.map`, `.reduce`, `.contains`, `for-in` direkt über das Array) oder
    auf `withUnsafe(Mutable)BufferPointer` angewiesen ist — für (b) bleibt
    `Array`, bis `InlineArray`s Span-APIs nachziehen.

    Nicht kompiliert/getestet (kein Swift-Toolchain-Zugriff hier) — User
    muss `swift test` + `ben --selftest` je Algorithmus laufen lassen.

## D. Spekulative Vorausberechnung (User-Idee, 2026-07-06)

12. ○ **Alle 16 Nibble-Pfade parallel vorberechnen.** Der Baum hat nur 4
    Bit-Ebenen / 16 Blätter. Während der Range-Decoder die aktuellen 4
    Bits noch sequenziell auswertet, ließen sich die Hash-Adressen für
    ALLE 16 möglichen Folgekontexte (die 16 möglichen `hist`-Werte nach
    diesem Nibble) im Voraus berechnen und per Software-Prefetch anstoßen
    — die Analogie zur CPU-Sprungvorhersage, nur dass hier die
    „Verzweigung" durch Vorabberechnung ALLER 16 Möglichkeiten aufgelöst
    wird statt geraten. Steht der tatsächliche Wert fest, ist die
    passende Tabellenzeile schon im Cache. Größter möglicher Gewinn
    (versteckt Speicherlatenz), aber auch größter Aufwand — braucht
    einen eigenen Prototyp zur Kosten/Nutzen-Abschätzung (Prefetch-
    Overhead vs. Ersparnis). Bijektivität unkritisch: reine Performance-
    Maßnahme, keine Modelländerung.
13. ○ Vorhersage- von Kodierphase trennen: alle Baumknoten-
    Wahrscheinlichkeiten VOR dem eigentlichen Bit-Decodieren berechnen
    (bessere Instruction-Level-Parallelität durch entkoppelte
    Abhängigkeitsketten), Lernupdate gebündelt nach dem ganzen Nibble
    statt pro Bit
14. ○ Kleiner Vorhersage-Cache (zuletzt gesehene Kontext/Node-Kombination)
    für hochredundante Bereiche (z. B. Alignment-Kontext bei Records) —
    spekulative Wiederverwendung statt Neuberechnung

## E. Architekturfrage (größerer Eingriff, nur nach Rücksprache)

15. ○ rANS statt adaptivem Binär-Range-Coder: batching-fähiger, SIMD-
    freundlicher, lockert die sequenzielle Bit-für-Bit-Abhängigkeit —
    betrifft nur das Coder-Backend, nicht den Markov-/Permutationskern,
    ist aber ein größerer Eingriff und sollte vor jedem Prototyp separat
    abgestimmt werden.

## F. Weitere Swift-6-Sprachfeatures (Recherche, 2026-07-06)

Was es sonst noch an neueren Swift-6-Features gibt, die uns helfen
könnten — jenseits von `InlineArray`:

17. ○ **`Span`/`RawSpan` (SE-0447, seit Swift 6.1/6.2).** Ein sicherer
    Ersatz für `UnsafeBufferPointer`/`UnsafeMutableBufferPointer` mit
    denselben Zugriffsgarantien wie ein Array, aber compile-time
    geprüfter Speichersicherheit statt Laufzeit-Bounds-Checks — laut
    Proposal für native Swift-Typen performanceidentisch zu
    `UnsafeBufferPointer`. **Das ist potenziell der größte Hebel von
    allen hier**: unser gesamtes safe/unsafe-Dual (jede Modellklasse
    UND jeder Coder existiert doppelt — einmal mit Swift-Arrays, einmal
    mit rohen Pointern) könnte langfristig auf EINE `Span`-basierte
    Implementierung zusammenschrumpfen, die beides zugleich wäre: sicher
    UND so schnell wie der heutige `--unsafe`-Pfad. Das ist ein größerer
    Umbau (betrifft alle Algorithmus-Dateien) und sollte separat mit dir
    abgestimmt werden, nicht nebenbei — aber es lohnt sich, das im Auge
    zu behalten, weil es unsere Code-Verdopplung grundsätzlich auflösen
    könnte statt sie nur zu optimieren.
18. ○ **`Synchronization`-Framework (`Mutex`, `Atomics`, seit Swift 6.0).**
    Low-Level-Primitiven ohne Locks-Overhead von `NSLock`/`DispatchQueue`.
    Für uns relevant, falls Blockparallelität (nbcmb/nbcmbf/künftiger
    ncmme-Blockmodus) mal einen gemeinsamen Fortschrittszähler oder eine
    Statistik über Threads hinweg braucht — aktuell sind unsere Blöcke
    komplett unabhängig (kein geteilter Zustand), daher bisher kein
    Bedarf, aber gut zu kennen für den ncmme-Blockmodus (Nr. 55/Speed-
    Rückstand aus dem letzten Gespräch).
19. ○ **`borrowing`/`consuming` Parameter-Modifikatoren (seit Swift 5.9,
    in Swift 6 generalisiert).** Reduzieren ARC-Retain/Release beim
    Funktionsaufruf, indem man explizit macht, ob ein Parameter nur
    gelesen (`borrowing`) oder übernommen (`consuming`) wird. Für uns
    denkbar an den `predict`/`update`-Methoden, falls Profiling zeigt,
    dass Funktionsaufruf-Overhead (statt Speicherzugriff) eine Rolle
    spielt — ohne Messung aber Spekulation, siehe Profiling-Empfehlung
    oben.
20. ○ **Noncopyable Generics (`~Copyable`, seit Swift 6.0).** Ermöglicht
    erst `InlineArray`, `Span` und `Mutex` als generische Typen. Für uns
    kein direkter Hebel, aber die Grundlage, auf der 16–18 aufbauen.

## Priorisierungsvorschlag

Quick-Win Nr. 11 zuerst (kleinster Aufwand, geringstes Risiko, sofort
messbar). Danach Profiling (Cache-Miss-Rate vs. Zeit im Mixer/in den
Hash-Lookups) als Entscheidungsgrundlage für 4/5/6/8 — ohne Messung ist
unklar, ob wir speicher- oder rechengebunden sind. Nr. 12 (spekulative
16-Wege-Vorberechnung) ist der interessanteste, aber aufwändigste
Kandidat — eigener Python- oder Swift-Mikrobenchmark vor Entscheidung.
Nr. 15 (rANS) nur bei grundsätzlichem Bedarf, nicht als Nebenschritt.
Nr. 16 (`InlineArray`) ist ebenfalls ein guter Kandidat für einen frühen
Schritt — ähnlich risikoarm wie Nr. 11, keine Python-Vorarbeit möglich
(reines Swift-Sprachfeature), also direkt als kleiner Swift-Patch mit
Vorher/Nachher-Zeitmessung testbar.
