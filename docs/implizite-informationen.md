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
2. ○ Noch tiefere Kontexte (Order-8+, nur Hash)
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
12. ⏸ Position mod 2/4/8/16 (Alignment: Structs, Records, 16/32-Bit-Werte) —
    ARCHITEKTUR-KONFLIKT (2026-07-04): braucht die Original-Byte-Position,
    die aber genau das ist, was die BWT beim Sortieren zerstört; der Decoder
    kennt die Original-Position eines Symbols erst NACH der vollständigen
    inversen BWT, nicht während des kausalen Dekodierens von `t`. Positions-
    basierte Kontexte (Nr. 11–18) sind strukturell an die BWT-freie ncmm-
    Linie gebunden, nicht an nbcm. Zurückgestellt (User-Entscheidung), nicht
    verworfen — möglich in ncmm oder als grober Zwei-Pass-Header-Wert.
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
34. ○ Exclusion im CM: vom Match-Modell ausgeschlossene Bits schärfen andere
    Modelle — bezieht sich laut Formulierung explizit auf ncmm/CM-Linie
    (geparkt), nicht auf nbcm; mit User zu klären, ob sinngemäße Übertragung
    auf nbcm gewünscht ist oder das Thema an ncmm gebunden bleibt

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
52. ○ Blocklängen-Sequenz selbst als Zeitreihe: die Abfolge der d-Werte bei
    jedem Blockende (Geburtstags-Kollisionsabstände) mit einem eigenen
    kleinen Markov-Modell (2. Ordnung) modellieren statt nur punktuell als
    Tabellenindex zu nutzen — umgeht das BWT-Positions-Kausalitätsproblem
    (Nr. 12/27), weil nur bereits beobachtete d-Werte gebraucht werden,
    keine Original-Position; könnte periodische Binärstrukturen indirekt
    sichtbar machen
53. ○ Prädiktive Vorverarbeitung vor der BWT (Delta/Residuen): exakt
    umkehrbare Delta-Transformation für numerische Binärdaten VOR der BWT,
    macht Permutationsblöcke länger/geburtstags-günstiger statt der BWT ein
    zusätzliches Signal aufzudrängen — bleibt architektur-kompatibel, weil
    sie vor der BWT ansetzt
54. ○ Wettbewerb mehrerer Roh-Transformationen pro Block: mehrere Varianten
    (Hi/Lo-Nibble-Reihenfolge vertauscht, Strom rückwärts, mit/ohne Delta)
    probieren, kompakteste behalten, 1 Header-Bit für die Wahl — Zeit ist
    laut Projektpriorität nachrangig, mehrfaches Komprimieren ist billig
55. ○ Wettbewerb ganzer Algorithmen pro Block: nbcm UND ein einfaches
    Order-0/1-Modell parallel rechnen, kleineres Ergebnis behalten (1
    Header-Bit) — zielt auf heterogene Korpora (Canterbury) ohne
    Dateityp-Klassifikator, die Kompression entscheidet selbst
56. ○ Rückwärtskodierung: Strom vor der BWT komplett umkehren — kostet
    nichts an Architektur, rein empirisch zu prüfen ob manche Dateiformate
    (Redundanz eher am Ende) davon profitieren

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

## Offene Kandidaten (erwarteter Gewinn auf enwik8)

| Nr. | Maßnahme | erwartet | Aufwand |
| --- | -------- | -------- | ------- |
| 47  | Block-Modus (Pflicht für enwik9, Basis für Parallelität) | — | mittel |
| 35  | zweite APM-Stufe (d-Kontext) | klein | klein |
| 15/14 | Spalten-Modell | mittel (Tabellen/Binär) | mittel |
| 45–50 | Zwei-Pass global | mittel | mittel |
| 39  | Statistikbruch-Detektor, Variante Hysterese (statt Ratio) | unklar, Ratio-Variante verworfen | klein |
| 39  | Statistikbruch-Detektor, Variante Kontext- statt Ereignisklassen-Ebene | unklar, Ratio-Variante verworfen | mittel |
| 46/47 | Dateityp-Segmentierung | unklar, hohes Risiko | groß |
| 52  | Blocklängen-Sequenz als Zeitreihe (Markov 2. Ordnung) | unklar, neuartig | mittel |
| 53  | Prädiktive Vorverarbeitung vor BWT (Delta/Residuen) | mittel, v.a. numerische Binärdaten | mittel |
| 54  | Wettbewerb mehrerer Roh-Transformationen pro Block | unklar | mittel |
| 55  | Wettbewerb ganzer Algorithmen pro Block | mittel, v.a. Canterbury | mittel |
| 56  | Rückwärtskodierung | unklar, vermutlich klein | sehr klein |

## Zurückgestellt (nicht verworfen, aber momentan nicht verfolgt)

| Nr. | Maßnahme | Grund |
| --- | -------- | ----- |
| 10  | Recency-Vektor | Gewinn real (0,006–0,2 %), aber unter bisheriger Schwelle |
| 12/27 | Alignment-/Wortbreiten-Kontext | Architektur-Konflikt: braucht Original-Position, die BWT zerstört; nur in ncmm oder als Zwei-Pass-Header-Wert sinnvoll |
