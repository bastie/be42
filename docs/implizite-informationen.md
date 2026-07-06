# Implizite Informationen einer Datei

<!--
 SPDX-License-Identifier: Apache-2.0
 SPDX-FileCopyrightText: © 2026 Sebastian Ritter
-->

Explizit bekannt sind nur: **Wert** (Byte/Nibble), **Position** des Wertes,
**Datenlänge**. Alles Weitere ist implizit — analytisch aus dem bereits
gesehenen Strom ableitbar und damit für Encoder UND Decoder identisch
verfügbar (Bijektivität bleibt erhalten). Dieser Katalog sammelt 50 solcher
Quellen. Status: ✓ = in ncmm genutzt, (✓) = teilweise, ○ = offen.

## A. Verlauf / Kontext (Markov verallgemeinert)

1. ✓ Vorangehende Werte fester Tiefe (Order-1/2/3/4/6)
2. (✓) Noch tiefere Kontexte (Order-8+, nur Hash) — in ncmm GEMESSEN
    (Schritt 13b): Order-8+12 (Hash, Prüfsumme, je 20 Bit) — Text-Gewinn
    wächst mit Dateigröße (enwik8 40K −0,22 %, 120K −0,51 %), der
    zpaq-Kapazitätsmechanismus; auf MB-Skala mehr zu erwarten
3. (✓)/✗ Position des letzten Auftretens desselben Kontexts (Match-Modell) —
    in ncmm genutzt; als Ergänzung zu nbcm (Match auf dem BWT-Ausgabestrom)
    GEMESSEN und verworfen (Schritt 6, siehe unten)
4. ✗ Das ZWEITLETZTE Auftreten (zweiter Match-Kandidat, Match-Ensemble) —
    hinfällig, da schon der einfache Match auf dem BWT-Strom keinen
    Mehrwert brachte (Schritt 6)
5. (✓) Übersprungene Kontexte (sparse): Byte[-2,-4] — in ncmm
6. (✓) Wort-Kontext: Hash der Buchstabenfolge seit letztem Trennzeichen — in ncmm
7. ○ Vorheriges vollständiges Wort (Wort-Bigramm)
8. ✓ Lauflänge des aktuellen Wertes (Run-Kontext in nbmec; ncmm: implizit)
9. ○ Distanz zum letzten Auftreten des gleichen BYTES (nicht Kontexts)
10. ⏸ Recency-Vektor: wann kam jeder der 16 Nibble-Werte zuletzt (MTF
    verallgemeinert) — ZURÜCKGESTELLT (Schritt 7): Gewinn real und überall
    positiv (0,006–0,2 % je nach Korpus), aber unter der Schwelle jedes
    bisher übernommenen Schritts — kein endgültiges Verwerfen, da der Gewinn
    vorhanden ist; ggf. später mit weiteren additiven Signalen kombiniert
    erneut bewerten

## B. Position (die zweite explizite Information als Kontextquelle)

11. ✓ Parität der Nibble-Position (Hi/Lo im Byte)
12. (✓) Position mod 2/4/8/16 (Alignment: Structs, Records, 16/32-Bit-Werte) —
    in nbcm ARCHITEKTUR-KONFLIKT (BWT zerstört Original-Position, 2026-07-04),
    aber in ncmm GEMESSEN (Schritt 13a, 2026-07-06): Byte-Position mod 8 als
    eigenes Kontextmodell bringt auf dem Zielfall (4-Byte-Stride-Binärdaten)
    −8,32 %, bei fester Record-Breite −0,19 %; Text leicht negativ
    (+0,2…+0,5 %). Bestätigt die These, dass Positions-Kontexte an die
    BWT-freie ncmm-Linie gebunden sind — dort funktionieren sie.
13. ○ Absolute Position grob (Dateianfang = Header, Rest = Daten)
14. ○ Spalte: Distanz seit letztem Zeilenumbruch
15. ○ Byte an gleicher Spalte der VORZEILE (Tabellen, festbreite Formate)
16. ○ Zeilenlänge der Vorzeile (sagt Umbruch voraus)
17. ○ Einrücktiefe der aktuellen Zeile (Code, XML)
18. ○ Dominante Wiederholdistanz (Stride-Erkennung → dynamische Sparse-Kontexte)

## C. Werteklassen und Syntax

19. ○ Byteklasse des Vorgängers (Buchstabe/Ziffer/Whitespace/Interpunktion/Binär)
20. ○ Groß-/Kleinschreibungs-Muster (Xx, XX, xx)
21. ○ UTF-8-Zustand: nach Startbyte sind Fortsetzungsbytes stark eingeschränkt
22. ○ Ziffernmodus: innerhalb einer Zahl sind Länge und Folgeziffern modellierbar
23. ○ Klammer-/Tag-Tiefe (XML/JSON: enwik8!)
24. ○ Zuletzt geöffnetes XML-Tag (schließendes Tag ist fast deterministisch)
25. ○ Delta zum Vorgängerbyte (numerische Reihen, Sensordaten)
26. ○ Zweite Ableitung / Steigungswechsel (Audio, Kurven)
27. ⏸ 16/32/64-Bit-Werte als Einheit, Little/Big-Endian-Deltas — derselbe
    Architektur-Konflikt wie Nr. 12 (Original-Position nach BWT nicht
    kausal verfügbar), zurückgestellt
28. ○ Gleitkomma-Zerlegung: Exponent und Mantisse getrennt modellieren
29. ○ Bitmasken-Spalten: Flags an fester Bitposition im Record

## D. Exclusion / Permutation (die Projekt-DNA)

30. ✓ Im aktuellen Block bereits gesehene Werte (nbmec-Exclusion)
31. ✓ Geburtstagsstatistik der Permutationslängen (nbmec)
32. ✗ Alphabetreduktion: Werte, die bisher NIE vorkamen (Nicht-Auftreten ist
    Information) — GEMESSEN (Schritt 8): verschlechtert ausgerechnet auf dem
    Zielfall (reduziertes Alphabet). `d` (bereits gesehene Werte im
    AKTUELLEN Exclusion-Block) erfasst Alphabet-Beschränkung schon implizit
    und schneller als ein globaler Zähler
33. ✗ Lokales Alphabet: distinct Werte im letzten Fenster (kleine Paletten →
    schärfere Vorhersage) — GEMESSEN (Schritt 8): dieselbe Redundanz mit `d`
    wie Nr. 32, ebenfalls verschlechtert auf dem Zielfall
34. ✗ Exclusion im CM: vom Match-Modell ausgeschlossene Bits schärfen andere
    Modelle — GEMESSEN in ncmm (Schritt 13c) als „gebrochener Match-Kandidat
    lebt als schwacher Low-Nibble-Prädiktor mit gelernter Verlässlichkeit
    weiter": überall neutral (+0,0…+0,2 %), das Signal feuert zu selten.
    Verworfen in dieser Interpretation; andere Deutungen des Katalogtexts
    (z. B. Subtree-Renormierung) wären eigene, neue Kandidaten.

## E. Statistik über die Statistik (zweite Ordnung)

35. ✓ Vorhersagefehler-Historie je Ereignisklasse (APM/SSE — in nbcm und ncmm)
36. ✓ Verlässlichkeit des Match-Modells je Matchlänge (APM Stufe 2 in ncmm)
37. ○ Konsens der Modelle (alle einig vs. uneinig) als eigener Kontext
38. ○ Lokale Komprimierbarkeit (Bits/Byte der letzten N Bytes) als Kontext
39. ✗/○ Statistikbruch-Detektor: Segmentwechsel → schnellere Adaption —
    EWMA-Ratio-Variante GEMESSEN und verworfen (nbcm Schritt 5): trennt
    nicht selektiv, wirkt wie eine feste schnellere Rate ohne deren Risiko
    zu rechtfertigen. Offen bleiben zwei ungeprüfte Varianten: (a) Hysterese
    (harter Zustandswechsel mit Ein/Aus-Schwellen statt stetiger Ratio),
    (b) Detektor auf Kontext-Ebene (pro Slot) statt Ereignisklasse.
40. ○ Anzahl bisheriger Updates eines Slots (Konfidenz) — als Mixer-Input statt nur Rate
41. ○ Alter der Statistik: Zeit seit letztem Update des Kontexts

## F. Hygiene der impliziten Information (Verluste vermeiden)

42. (✓) Hash-Prüfsummen: Kollisionen erkennen und Slot zurücksetzen — in ncmm
43. ✗ Bit-History je Slot: GEMESSEN und verworfen — die Permutationsstruktur
    (Lauflänge, d, MTF) IST bereits die relevante Historie (nbcm Schritt 2)
44. ✓ Getrennte schnelle + langsame Statistik je Kontext, gemischt — in nbcm (Schritt 1)

## G. Globale Sicht (Zeit/RAM nachrangig — Zwei-Pass erlaubt)

45. ○ Pass 1 über die GANZE Datei: exakte globale Statistiken in den Header
46. ○ Dateityp-Erkennung (Magic Bytes) → Modell-Vorwahl pro Datei
47. ○ Segmentierung der Datei in homogene Abschnitte, Modellwahl je Segment
48. ○ Optimale Parameterwahl (Lernraten, Mixer-Kontexte) per Probelauf, im Header kodiert
49. ○ Wörterbuch-Vorlauf: häufigste Wörter/Phrasen einmalig, dann Referenzen
50. ○ Kanalzerlegung: Datei als N verschachtelte Ströme (Spalten) getrennt kodieren

## H. Neue Ansätze (2026-07-04, nach vier additiven Signalen die alle an
derselben Redundanz scheiterten: BWT-Sortierung, MTF-Rang, `d` kapseln
Kontext/Recency/Alphabetgröße bereits implizit — neue Kandidaten müssen
entweder andersartige Information oder eine strukturelle Änderung liefern)

51. ✗ Geburtstagsformel als theoretisch informierter Prior — GEMESSEN
    (Schritt 9) und verworfen: hilft/schadet je nach Korpus, im Mittel ein
    Nullsummenspiel. Grund: die Uniform-über-16-Annahme, aus der d/16 bzw.
    1/(total−j) folgen, trifft auf reale (auch nach BWT) Daten oft NICHT zu
    — bei restrukturiertem/eingeschränktem Alphabet ist die Abweichung
    systematisch und bleibt bestehen (keine bloße Kaltstart-Delle), der
    "falsche" Prior kostet dann durchgehend statt nur am Anfang. Siehe
    Messdetails unten.
52. ✗ Blocklängen-Sequenz selbst als Zeitreihe — GEMESSEN (Schritt 12) und
    verworfen: die Autokorrelation der L-Sequenz (Kettenlängen bei
    Blockende) ist auf realistischen periodischen Korpora (Records mit
    Nutzdaten-Rauschen) praktisch NULL (Lag 1/2/3/16: −0,01…+0,02) — die
    BWT-Sortierung zerstört die Positionsperiodizität der Quelle so
    gründlich, dass in der d-Sequenz kein Signal überlebt. Selbst im
    künstlichen Extremfall (nahezu konstante Daten) taucht Autokorrelation
    nur dort auf, wo sie mit dem bereits genutzten `runlen`-Kontext
    (d=1-Fall) zusammenfällt — wieder dieselbe Redundanz-Diagnose wie
    Schritt 6/7/8. Details unten.
53. ✓ Prädiktive Vorverarbeitung vor der BWT (Delta/Residuen) + Nibble-
    Planarisierung (User-Vorschlag "Nibble-Planar-Delta-Filter", 2026-07-04)
    — GEMESSEN UND ÜBERNOMMEN (Schritt 10): auf Zielfall (32-Bit-Werte mit
    strukturierten High-/verrauschten Low-Bytes) −33 % (8118→5432 B).
    WICHTIGE KORREKTUR am ursprünglichen Vorschlag: die vorgeschlagene
    Heuristik (kleinster Byteabstand zu 0) UND die unbedingte Planarisierung
    haben auf Text/homogenen/heterogenen Korpora massiv geschadet (bis zu
    +56 %!), weil sie Delta/Planarisierung auch dort erzwangen, wo die
    Byteverteilung dagegen spricht. Lösung: pro Block mehrere Varianten
    (kein Filter / nur Delta / nur Planar / beides, Stride per
    Entropie-Heuristik vorausgewählt) TATSÄCHLICH komprimieren und die
    kleinste Ausgabe behalten (Idee Nr. 54, Wettbewerbsprinzip) — garantiert
    per Konstruktion nie schlechter als ohne Filter (Header-Overhead
    2 Byte), erkennt den Zielfall UND verbessert nebenbei den Fall
    reduziertes Alphabet (−6,4 %). Bijektiv getestet. Nächster Schritt:
    Swift-Portierung.
54. ✓ Wettbewerb mehrerer Roh-Transformationen pro Block — ÜBERNOMMEN als
    Auswahlmechanismus innerhalb von Schritt 10 (Nr. 53): rettet die
    Delta/Planar-Idee vor der eigenen schlechten Heuristik, da die
    tatsächlich kleinste Ausgabe entscheidet statt einer Vorab-Schätzung.
    Erkenntnis verallgemeinerbar: weitere Rohtransformationen (rückwärts
    lesen, Nr. 56) könnten über denselben Mechanismus mitgeprüft werden
55. ○ Wettbewerb ganzer Algorithmen pro Block: nbcm UND ein einfaches
    Order-0/1-Modell parallel rechnen, kleineres Ergebnis behalten (1
    Header-Bit) — zielt auf heterogene Korpora (Canterbury) ohne
    Dateityp-Klassifikator, die Kompression entscheidet selbst
56. ○ Rückwärtskodierung: Strom vor der BWT komplett umkehren — kostet
    nichts an Architektur, rein empirisch zu prüfen ob manche Dateiformate
    (Redundanz eher am Ende) davon profitieren
57. ✗ LZ-Wörterbuch-Vorverarbeitung: häufige Wörter durch ungenutzte
    Byte-Werte vor der BWT ersetzen (Wörterbuch im Blockheader, bijektiv,
    kein LZ77-Offset-Einbetten) — GEMESSEN (Schritt 11) und verworfen:
    verliert auf ALLEN Korpora inklusive Zielfall enwik8 (+3,3 %), und
    zwar bereits im STROM selbst (ohne Headerkosten: +139…+903 B je nach
    Wörterbuchgröße 8…128). Auch nibble-schonende Code-Vergabe (Codes mit
    im Block häufigen Nibbles) rettet nichts (+148 B Bestfall). Diagnose
    (doppelt): (a) die BWT bündelt jedes Vorkommen eines häufigen Wortes
    ohnehin in benachbarte Kontexte — das 100. „the " kostet fast nichts,
    die Substitution kann nicht sparen, was schon nichts kostet; (b) die
    Code-Bytes stammen zwangsläufig aus UNGENUTZTEN Byte-Werten und
    blähen das effektive Nibble-Alphabet auf (d steigt, Ketten länger) —
    die Schritt-8-Erkenntnis („kleines Alphabet = unser Vorteil") in
    umgekehrter Richtung. WRT-Gewinne aus der bzip2-Literatur beruhen auf
    Schwächen (Huffman-Overhead je Symbol), die unser adaptiver
    Exclusion-Coder nicht hat. Wettbewerb (Nr. 54) hat korrekt „roh"
    gewählt — Pipeline blieb risikofrei.
58. ✓ GPU-beschleunigte Suffix-Array-Sortierung via MPSGraph-ArgSort —
    UMGESETZT (0.52.0, --gpu Schalter; Messung auf Apple-Hardware offen,
    Verwerfen laut User-Vorgabe nicht vorgesehen). Bitidentität PER
    KONSTRUKTION statt per Stabilitäts-Hoffnung gelöst: (a) Rangvergabe je
    Doubling-Runde hängt nur von Schlüssel-GLEICHHEIT benachbarter
    Elemente ab → instabiler ArgSort über gepackte Int64-Paarschlüssel
    (rank<<32|rank2) liefert identische Rang-Evolution wie die zwei
    stabilen CPU-Counting-Sorts; (b) einziger stabilitäts-sensitiver Punkt
    ist der finale Tiebreak identischer Rotationen (periodische Eingaben —
    der BWT-Index hängt daran!) → finales SA wird IMMER aus den End-Rängen
    per stabilem CPU-Counting-Sort normalisiert (Ordnung Rang, dann Index
    = exakte CPU-Semantik); (c) Int64-Unterstützung von ArgSort ist
    undokumentiert → einmalige Laufzeit-Probe (inkl. >32-Bit-Schlüssel),
    bei Fehlschlag transparenter CPU-Fallback — --gpu ändert nie die
    Ausgabe. Unified Memory: Schlüssel direkt in storageModeShared-Puffer
    (kein Transfer); Rang-Scan bleibt CPU (sequenziell). OFFEN: Messung
    Graph-Overhead pro Runde (~27 Runden/Block) — falls er dominiert, ist
    Plan B ein eigener Metal-Compute-Radix-Sort (Count→Scan→Scatter),
    Design unverändert. RAM-Hinweis: +16 B je Eingabe-Byte für den
    Schlüsselpuffer pro parallelem Block. GEMESSEN (2026-07-06, enwik8,
    nbcm, 1 Thread): 1:06,93 statt 2:13,65 Gesamtzeit — 2,0× schneller;
    CPU-Rechenzeit 42,98 s statt 130,96 s (Faktor 3,0), CPU während der
    GPU-Sortierung nur 68 % ausgelastet (Rest steht parallelen Blöcken zur
    Verfügung). Der Graph-Overhead pro Runde frisst den Gewinn NICHT auf —
    Plan B (eigener Metal-Radix-Sort) vorerst unnötig.
59. ⏸ Theoretische Obergrenze: zpaq liegt auf enwik8 bei ~19,6 % (vs. unser
    22,6 %), Grund nicht ein einzelner Trick sondern KAPAZITÄT — hunderte MB
    parallel laufender Kontextmodelle (Order-1..8+, Wort, Sparse, Match) mit
    Bit-History statt unserer 183 Slots. Der BWT erledigt schon Kontextbündelung
    für uns und quantisiert den Kontext in Permutations-/Rang-Struktur
    (d, MTF-Rang, Lauflänge). Schritte 5-9 bestätigen empirisch: diese Struktur
    enthält bereits fast alles, was sie KANN enthalten. An zpaq heranzukommen
    hieße, zusätzliche Modellkapazität NEBEN der BWT aufzubauen — kein einzelner
    Trick, kein Block-Algorithmus-Wettbewerb (Nr. 55) können das kompensieren
    ohne grundlegende Architektur (Zwei-Linie: nbcm vs. ncmm) zu ändern. Zur
    Kenntnis für Roadmap-Realismus genommen, nicht verworfen (könnte ncmm-
    Ausbau motivieren, aber ist außerhalb des nbcm-Kerns).

## Messergebnisse der nbcm-Schritte (enwik8, kumulativ)

| Schritt | Maßnahme | Ergebnis |
| ------- | -------- | -------- |
| Basis (nbmec 0.43) | Exclusion + adaptive Probs | 22.805.378 B |
| 1 (Nr. 44) | Dual-Rate + Slot-Mixer | 22.614.977 B |
| 2 (Nr. 43) | Slot-Bit-Historie | verworfen (verschlechtert) |
| 3 | Vor-Nibble-Konditionierung | verworfen (Verdünnung) |
| 4 (Nr. 35) | APM/SSE je Ereignisklasse | 22.592.372 B |
| 5 (Nr. 39) | Statistikbruch-Detektor (EWMA kurz/lang, global UND je Ereignisklasse) | verworfen (siehe unten) |
| 6 (Nr. 3/4) | Match-Ensemble auf BWT-Ausgabestrom | verworfen (siehe unten) |
| 7 (Nr. 10) | Recency-Vektor (Alter je Kandidat, log2-Bucket) | zurückgestellt (siehe unten) |
| 8 (Nr. 32/33) | Alphabetreduktion + Lokales Alphabet | verworfen (siehe unten) |
| 9 (Nr. 51) | Geburtstagsformel als Prior (statt Uniform-Start) | verworfen (siehe unten) |
| 10 (Nr. 53/54) | Nibble-Planar-Delta-Filter im Wettbewerb | ÜBERNOMMEN (0.51.0, nbcmbf) |
| 11 (Nr. 57) | Wörterbuch-Vorverarbeitung vor der BWT | verworfen (siehe unten) |
| 12 (Nr. 52) | Blocklängen-Sequenz (d-Historie) als Slot-Kontext | verworfen (siehe unten) |
| 13 (Nr. 59: 12/27, 2, 34) | ncmm-Ausbau: Alignment + Order-8/12 + Match-Exclusion | 12/27 ✓, 2 ✓ (skaliert), 34 neutral (siehe unten); Swift/ncmme: enwik8 24,11 % (−2,59 % vs. ncmm), silesia 22,77 % |

**Schritt 5 im Detail (2026-07-04, ben_nbcm5_proto.py):** EWMA-Paar von `\|err\|`
(kurzes/langes Zeitfenster) je Ereignisklasse, additiver Floor gegen
Cold-Start-Instabilität, bei Überschreiten Beschleunigung von fast/slow-Shift
für dieses Update. Getestet auf synthetischem heterogenem Korpus (Text →
Code-Token → Binärrauschen → Lauflängen-Binär → Text, starke Brüche) und auf
homogenem Korpus (corpus.bin). Ergebnis: bestenfalls −0,7 % auf dem
heterogenen Korpus, aber der Detektor löst 60–90 % aller Entscheidungen als
"Bruch" aus (statt selektiv an echten Übergängen) — er wirkt kaum anders als
eine global fest verdrahtete schnellere Rate, die denselben Gewinn (−0,5 %)
ohne jeden Detektor liefert. Auf dem homogenen Korpus verschlechtert sowohl
der Detektor als auch die feste schnellere Rate um +0,3…+1 %. Fazit:
kein sauberes Signal für echte Segmentwechsel gefunden, Aufwand/Risiko
(Bijektivität, Zwei-Zustands-Komplexität) steht in keinem Verhältnis zum
Gewinn → verworfen wie Schritt 2/3. Offen bleibt, ob ein Detektor auf
Kontext-Ebene (statt Ereignisklasse) oder mit hartem Zustandswechsel
(Hysterese statt Ratio) besser trennt — nicht weiterverfolgt ohne neuen
Ansatz.

**Schritt 6 im Detail (2026-07-04, ben_nbcm6_proto.py):** Hash der letzten
6 Nibbles des BWT-Ausgabestroms `t` → letzte Position; solange bestätigt,
liefert die dortige Fortsetzung einen dritten Mixer-Eingang (neben
fast/slow) mit eigener adaptiver Zuverlässigkeit je Matchlänge-Bucket
(wie in ncmm). Getestet: homogener Korpus (corpus.bin, neutral, −0,05 %),
binäre Records mit exakten Wiederholungen über Distanz (silesia-Ersatz,
+0,2 % schlechter), Extremfall 8× exakte Wiederholung eines 300-Byte-Blocks
(bestmöglicher Fall für ein Match-Modell: Match 77 % der Zeit aktiv, 78,7 %
korrekt — trotzdem +1,4 % schlechter als ohne). Mit schnellerem Mixer-Lernen
(`lr_shift=8`) lernt der Mixer das Match-Gewicht exakt auf 0 herunter
(Ergebnis identisch zur Baseline) — der Mixer selbst "entscheidet", dass
das Match-Signal nichts beiträgt. Diagnose: die BWT sortiert bereits nach
Kontext und bündelt exakte Wiederholungen unabhängig von ihrer Distanz in
Läufe (Run-Kontext in nbmec/nbcm) — ein Match-Modell AUF dem BWT-Ausgabestrom
liefert daher redundante Information zu dem, was Exclusion-Kette + Lauflänge
bereits erfassen; die Vorhersagegüte des Matches (79 %) liegt deutlich unter
dem, was der Run-Kontext an dieser Stelle ohnehin schon erreicht. Verworfen.
Offene Frage für später: ein Match-Modell auf dem ROHEN Byte-/Nibble-Strom
VOR der BWT (wie in ncmm) könnte prinzipiell andersartige Information liefern
— das würde aber zwei fundamental verschiedene Pipelines mischen und die
geparkte ncmm-Linie wieder aufgreifen; nicht ohne erneute Grundsatzentscheidung
weiterverfolgt.

**Schritt 7 im Detail (2026-07-04, ben_nbcm7_proto.py):** pro Kandidat c in
der Exclusion-Kette Abstand seit letztem Auftreten (`pos - lastSeen[c]`,
echte Zeit über Blockgrenzen hinweg, log2-Bucket, 32 Buckets) als dritter
Mixer-Eingang, eigene adaptive P(hit|Bucket). Getestet auf denselben drei
Korpustypen wie Schritt 5/6: homogen (corpus.bin voll, 247 KB) −3 Byte
(0,006 %), heterogen (canterbury-artig) −3 Byte (0,18 %), binär mit
Record-Wiederholungen (silesia-Ersatz) −4 Byte (0,18 %). Anders als beim
Match-Ensemble überall in dieselbe (positive) Richtung, aber durchweg unter
der Schwelle jedes bisher übernommenen Schritts (Schritt 1: 0,84 %, Schritt 4:
0,31 %). Verfeinerungsversuch (48 statt 32 Buckets, feinere Auflösung im
Nahbereich) verschlechterte das Ergebnis leicht — mehr Parameter verdünnen
wieder, wie schon in Schritt 3 beobachtet. Diagnose: der MTF-Rang (bereits
als Kettenposition j im Kontext verwendet) IST selbst schon eine grobe
Recency-Rangfolge; das exakte Alter liefert nur eine marginale Verfeinerung
dieser bereits vorhandenen Information — daher real, aber strukturell
begrenzt. Verworfen: Gewinn zu klein, um Implementierungs-/Wartungsaufwand
und Bijektivitätskomplexität (Recency-Zustand über Blockgrenzen) zu
rechtfertigen.

**Schritt 8 im Detail (2026-07-04, ben_nbcm8_proto.py):** globaler
Auftrittszähler je Wert (Nr. 32, log2-Bucket) und Distinct-Werte-Zahl in
gleitendem 64er-Fenster (Nr. 33) als additive Mixer-Eingänge, einzeln und
kombiniert getestet — inklusive eines eigens für diesen Zielfall gebauten
Korpus mit auf 6 von 16 Werten reduziertem Alphabet. Ergebnis: auf
heterogenem Korpus leichter Gewinn kombiniert (1708→1702 B, −0,35 %), auf
binärem Record-Korpus neutral bis leicht schlechter, aber auf dem
EIGENTLICHEN ZIELFALL (reduziertes Alphabet) durchweg SCHLECHTER
(1427→1434…1439 B, +0,5…+0,8 %). Diagnose: `d` (Anzahl bereits gesehener
Werte im aktuellen Exclusion-Block, ohnehin zentraler Kontext) konvergiert
bei einem kleinen Alphabet sehr schnell auf dessen tatsächliche Größe und
erfasst die Beschränkung damit implizit und schneller, als ein globaler
oder gefensterter Zähler es explizit nachliefern kann — dieselbe
Redundanz-Diagnose wie bei Match-Ensemble (Schritt 6) und Recency (Schritt 7),
diesmal bezogen auf `d` statt auf die BWT-Sortierung bzw. den MTF-Rang.
Verworfen.

**Schritt 11 im Detail (2026-07-06, ben_nbcm11_proto.py):** Wörterbuch-
Transform als fünfte Wettbewerbs-Variante: Kandidaten = Buchstabenfolgen
(2–32) plus Varianten mit führendem Leerzeichen, Score = Vorkommen×(Länge−1)
− Headerkosten, Codes = im Block ungenutzte Byte-Werte (dadurch bijektiv
ohne Escape: Ein-Pass-Expansion ist exakt invers). Gemessen auf enwik8[:150K]
(echter Zielfall), corpus.bin, heterogen, binär, reduziertem Alphabet,
struct+rauschen. Ergebnis: Wettbewerb wählt ÜBERALL „roh" bzw. die
bestehenden Delta/Planar-Sieger; die Dict-Variante verliert selbst auf
enwik8 mit +3,3 % gesamt und +139…+903 B allein im Strom (Kaskade über
Wörterbuchgrößen 8/16/32/64/128 — Minimum bei 16–32, aber nie unter
Baseline). Nibble-schonende Code-Vergabe (freie Bytes mit häufigen
High/Low-Nibbles zuerst) bestätigt die Diagnose: bestenfalls +148 B.
Kernerkenntnis: BWT+Exclusion besetzen die Wortredundanz bereits
(Wiederholungskosten ~0 nach Kontextsortierung), und jede Substitution
durch ungenutzte Werte VERGRÖSSERT das Nibble-Alphabet — genau die Größe,
von deren Kleinheit der Geburtstags-Mechanismus lebt. Dieselbe
Redundanz-Diagnose wie Schritt 6 (Match auf BWT) und Schritt 8 (Alphabet-
signale), diesmal auf der Transformations- statt der Signalebene.
Konsequenz für Nr. 55/56: Rohtransformationen, die das Alphabet ERHALTEN
(Rückwärtslesen) oder den Coder wechseln (Algorithmen-Wettbewerb), bleiben
aussichtsreicher als solche, die neue Symbole einführen.

**Schritt 13 im Detail (2026-07-06, ben_cm4_proto.py — ncmm-Linie, Nr. 59):**
Grundprinzip unangetastet (User-Bestätigung dokumentiert); drei einzeln
schaltbare Erweiterungen auf cm3s-Basis (Basis bitidentisch zu cm3s
verifiziert), Bijektivitäts-Matrix aller 8 Schalterkombinationen bestanden,
jede Messung mit Roundtrip-Assert. (a) **Alignment Nr. 12/27** (Byte-Position
mod 8 als eigenes Kontextmodell — in ncmm kausal verfügbar, der
Architektur-Konflikt der nbcm-Linie existiert hier nicht): Zielfall
struktur+rauschen (4-Byte-Stride) **−8,32 %**, periodische Records −0,19 %,
Text leicht negativ (enwik8 +0,22 %, heterogen +0,46 %) — wirkt exakt wie
konstruiert; die kleine Text-Verwässerung ist der Preis ohne
Wettbewerbsmechanismus (ncmm ist Ein-Strom, kein Block-Wettbewerb).
(b) **Order-8/12 Nr. 2** (Hash + Prüfsumme, je 20 Bit): Text-Gewinn WÄCHST
mit der Dateigröße — enwik8 40K: −0,22 %, 120K: −0,51 % — das ist der
zpaq-Kapazitätsmechanismus (Nr. 59-Diagnose) in Aktion; auf MB-Skala ist
deutlich mehr zu erwarten, Binärkorpora neutral. (c) **Match-Exclusion
Nr. 34** (gebrochener Match-Kandidat lebt als schwacher Low-Nibble-Prädiktor
mit gelernter Verlässlichkeit weiter): überall neutral (+0,0…+0,2 %) — das
Signal feuert zu selten bzw. trägt keine Information; ehrliches Nullresultat.
Kombination „alle": vereint Align-Gewinn (struct −8,31 %) und Deep-Gewinn,
Text-Verwässerung durch Align bleibt (−0,03 % enwik8 40K). Empfehlung:
Swift-Port mit align+deep an, excl aus; Messung auf vollem enwik8/silesia
entscheidet, ob ncmm als Zweitlinie (ggf. später im Nr.-55-Wettbewerb)
antritt.

**Swift-Port ncmme (0x07, 0.53.0) — volle Korpusmessung (User, 2026-07-06,
`--unsafe`):** enwik8 24.112.243 B (24,11 %) in 3:13, gegenüber ncmm V3
(24.753.025 B, 24,75 %) **−2,59 %** — der Order-8/12-Kapazitätsgewinn
bestätigt sich auf voller Dateigröße, größenordnungsmäßig konsistent mit
dem in Python beobachteten Skalierungstrend (40K → 120K). silesia.tar
48.254.174 B (22,77 %) in 5:31 — schlägt sowohl das alte nbcmb (vor dem
Filter-Wettbewerb, 51.803.644 B, 24,44 %, **−6,85 %**) als auch
`xz -9ef` (48.928.248 B, 23,08 %, **−1,38 %**) auf diesem binärlastigen
Korpus. Damit erstmals eine reale (nicht nur Python-Zielfall-)Bestätigung,
dass der Alignment-Kontext auf echten strukturierten Binärdaten greift —
ncmme ist auf silesia sogar besser als die aktuelle nbcmbf-Produktionslinie
war, bevor deren Filter-Wettbewerb (Schritt 10) kam. Offen: direkter
ncmme-vs-nbcmbf-Vergleich auf demselben Korpusstand, und ob sich eine
Rolle im Nr.-55-Blockwettbewerb lohnt.

**Schritt 12 im Detail (2026-07-06, ben_nbcm12_proto.py):** d-Historie
(Länge der letzten ein bzw. zwei abgeschlossenen Exclusion-Ketten, grob in
3–4 Buckets à la Geburtstagserwartung ~5–6) als zusätzliche Dimension der
is_rep-Kontextslots — bewusst als SLOT-ERWEITERUNG (Variante B, wie die
erfolgreichen Schritte 1/4), nicht als drittes Mixer-Signal (Variante A,
wie die gescheiterten Schritte 6/7/8). Getestet auf sieben Korpora
inklusive eines eigens gebauten Zielfalls (Records fester Breite mit
Nutzdaten-Rauschen, gedacht für periodische Binärstrukturen). Ergebnis:
Ordnung 1 überall statistisch neutral (−0,06…+0,35 %, im Rauschen),
Ordnung 2 überall schlechter (+0,21…+2,05 %) — dieselbe Verdünnung wie
bei der Schritt-7-Verfeinerung und Schritt 3. Diagnostischer Zusatztest
(Autokorrelation der L-Sequenz direkt am BWT-Ausgabestrom, nicht nur die
Kompressionsgröße): auf dem realistischen periodischen Zielfall ist die
Autokorrelation bei Lag 1/2/3/16 praktisch NULL (−0,01…+0,02) — die BWT
sortiert nach lexikografischem Kontext, nicht nach Original-Position, und
zerstört damit die Positionsperiodizität der Quelle vollständig, bevor sie
in der d-Sequenz sichtbar werden könnte. Im künstlich konstruierten
Extremfall (nahezu konstante Daten, nur ein Rausch-Nibble pro Record)
zeigt sich zwar Autokorrelation (Lag 1: 0,54), aber sie beschränkt sich
auf exakt die Fälle, in denen ohnehin schon lange Läufe vorliegen — also
denselben Bereich, den der bestehende `runlen`-Kontext (genutzt wenn d=1)
bereits abdeckt. Damit bestätigt sich zum vierten Mal (nach Schritt 6, 7,
8) dieselbe Grunddiagnose, diesmal auf einer neuen Ebene: nicht nur MTF-
Rang und `d` sind bereits die relevante Historie, auch die Sequenz DER
Kettenlängen selbst enthält (nach der BWT) kein zusätzlich nutzbares
Signal — die Sortierung ist strukturell blind für Position und damit auch
für jede Periodizität, die nur über Position sichtbar wäre. Verworfen.

**Schritt 9 im Detail (2026-07-04, ben_nbcm9_proto.py):** Repeat-Bit-Slots
(d=2..15) mit d/16, Exclusion-Ketten-Slots mit der Hazard-Rate 1/(total−j)
initialisiert statt uniform 2048; Run-Slots unverändert. Getestet auf
heterogenem, binärem (Record-Wiederholungen) und reduziertem Alphabet
sowie einer direkten Simulation des Canterbury-Falls (vier kurze,
unabhängig komprimierte Einzeldateien). Ergebnis durchwachsen: binäre
Record-Daten leicht besser (2255→2247 B, −0,35 %), heterogener Korpus
leicht schlechter (1708→1711 B, +0,18 %), reduziertes Alphabet klar
schlechter (1427→1444 B, +1,2 %), Canterbury-Simulation in Summe exakt
NULL (541→541 B — Gewinne und Verluste auf einzelne Dateien heben sich
auf). Ablationstest (nur Repeat-Bit-Prior vs. nur Ketten-Prior) zeigt:
Schaden kommt überwiegend aus den Ketten-Priors, aber auch dort ist die
Wirkung je Korpus gegensätzlich (schadet bei reduziertem Alphabet, hilft
bei binären Records) — keine sicher abtrennbare "gute Hälfte". Diagnose:
die Uniform-über-16-Annahme trifft auf reale Daten oft nicht zu; bei
eingeschränktem/schiefem Alphabet ist die Abweichung systematisch und
bleibt über die GANZE Datei bestehen, nicht nur am Anfang — der falsche
Prior kostet dann durchgehend statt nur transient beim Einschwingen.
Verworfen als globale Standardänderung.

## Offene Kandidaten (erwarteter Gewinn auf enwik8, geordnet nach Priorität/Realismus)

| Nr. | Maßnahme | erwartet | Aufwand | Kategorie |
| --- | -------- | -------- | ------- | --------- |
| 56  | Rückwärtskodierung (Wettbewerb mit Reverse-Variante) | unklar, vermutlich klein | sehr klein | Ratio (schnell) |
| 55  | Wettbewerb ganzer Algorithmen pro Block (nbcm vs. Order-0/1) | mittel, v.a. Canterbury | mittel | Ratio |
| 58  | GPU-Sortierung (Metal MPSGraph) — 0.52.0 umgesetzt, Messung offen | — (Speed-only) | erledigt | Speed |
| 45–50 | Zwei-Pass global (Dateityp, optimale Parameter) | mittel | mittel–groß | Ratio |
| 39  | Statistikbruch-Detektor, Varianten Hysterese oder Kontext-Ebene | unklar, Ratio-Variante verworfen | klein–mittel | Ratio |
| 15/14 | Spalten-Modell (Tabellen, festbreite Daten) | mittel (nur bei passenden Typen) | mittel | Ratio |
| 35  | zweite APM-Stufe (d-Kontext) | klein | klein | Ratio |
| 46/47 | Dateityp-Segmentierung (hohes Risiko) | unklar | groß | Ratio |
| 59  | ncmm-Ausbau (weitere Kontextmodelle, Zwei-Linie-Integration) | unbegrenzt, aber außerhalb nbcm-Kern | sehr groß | Strategic |

## Zurückgestellt (nicht verworfen, aber momentan nicht verfolgt)

| Nr. | Maßnahme | Grund |
| --- | -------- | ----- |
| 10  | Recency-Vektor | Gewinn real (0,006–0,2 %), aber unter bisheriger Schwelle |
| 12/27 | Alignment-/Wortbreiten-Kontext | Architektur-Konflikt: braucht Original-Position, die BWT zerstört; nur in ncmm oder als Zwei-Pass-Header-Wert sinnvoll |
| 59  | zpaq-Kapazität zum Vergleich | kein einzelner Bug-Fix, sondern Modellgrößen-Unterschied (100er MB vs. 183 Slots); außerhalb nbcm-Kern, würde ncmm-Ausbau rechtfertigen |
