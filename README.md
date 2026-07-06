# beNibble

<!--
 SPDX-License-Identifier: Apache-2.0
 SPDX-FileCopyrightText: © 2026 Sebastian Ritter
 -->

## Idee

Nahezu(? oder) alle Kompressionsalgorithmen betrachten eine Datei als Byte-Strom mit den expliziten Informationen Byte-Offset und Byte-Wert. Die meisten ersetzen wiederkehrende Sequenzen durch Referenzen — und ja, das funktioniert hervorragend.

Dieser Kompressionsalgorithmus schaut anders hin und nutzt eine andere Sicht auf die Datei: die **Dateistruktur als Kompressionsgrundlage**. Jede Datei lässt sich beschreiben als wiederholter Teil von Permutation von Werten. Eine Permutation endet mit dem ersten wiederholten Wert. Dieser Wert kann auch als Bindeglied zweier Permutationen gesehen werden, denn die eine endet mit ihm und die nächste beginnt mit ihm. Am Ende kann ein Rest bleiben.

Ein Beispiel (auf Nibble- statt Byte-Basis):

```
01 0A 07 04 0A 03 03 05 0A 07 04 0A 0F
 |           |     |              |
Start        |     |              |
      Wiederholung |              |
      auch Start   |              |
            Wiederholung    Wiederholung
            auch Start      auch Rest
```

Zu den Eigenschaften der Nibble-Permutation: Die Maximalgröße ist 16 (0123456789ABCDEF), aber bei Zufallsdaten sagt uns das Geburtstagsparadoxon, dass die meisten wohl 5 bis 6 Elemente lang sind. Außerdem steigt die Wahrscheinlichkeit eines wiederholten Wertes mit jedem weiteren Wert — beginnend bei 1/15, dann 1/14, 1/13 … bis 1/1. Das verhält sich wie eine **Markov-Kette**.

Hinweis: Der Algorithmus beruht auf menschlicher Intelligenz, Teile des Codes wurden jedoch zunächst von künstlicher Intelligenz geschrieben (Vibe Coding) und anschließend von Menschen überarbeitet — das Ergebnis hat Priorität.

### Exclusion-Kodierung (nbmec, Standard seit 0.43.0)

Die erste Implementierung (*nbbmr*) kodierte die Identität des nächsten Wertes innerhalb einer Permutation noch mit uniformen Kosten. Die bessere Frage ist die umgekehrte: Statt zu kodieren, WAS der nächste Wert ist, kodieren wir für die wahrscheinlichsten Kandidaten, dass ein Wert es NICHT ist — eine Kette binärer Ausschluss-Entscheidungen. Der letzte verbleibende Kandidat ist implizit und kostet null Bit.

- Kandidaten sind nach Aktualität geordnet (Move-to-Front); der Treffer beendet die Kette
- die Markov-Eigenschaft von oben (Wiederholungswahrscheinlichkeit wächst mit der Permutationslänge) wird adaptiv je Länge gelernt statt angenommen
- Läufe (nach der Nibble-BWT häufig) erhalten eigene Kontexte je Lauflänge
- alles wird mit einem adaptiven binären Range-Coder kodiert (LZMA-Stil, 11-Bit-Wahrscheinlichkeiten)

Keine Häufigkeitstabellen, kein Anhang: Der Decoder spielt das identische Modell vorwärts nach, die Dekompression ist deshalb bijektiv mit nur 8 Byte Payload-Header (Nibble-Anzahl + BWT-Index).

### Context-Mixing (ncmm, Standard seit 0.44.0)

Der nächste Schritt wertet mehr der impliziten Informationen aus, die eine Datei trägt — direkt auf dem Nibble-Strom, ohne BWT:

1. **Kontext**: die vorangehenden Nibbles mehrerer Ordnungen (bis 6 Byte tief) gleichzeitig — die Markov-Ketten-Idee auf mehrere Tiefen verallgemeinert
2. **Position im Byte**: High- und Low-Nibble haben völlig unterschiedliche Verteilungen (die Parität der Position ist implizite Information)
3. **Position des letzten Auftretens**: ein Match-Modell merkt sich, wo derselbe Byte-Kontext zuvor auftrat, und sagt die Fortsetzung voraus — die Wert-Position als implizite Information; der Match-Zustand konditioniert zusätzlich den Mixer und die SSE-Stufe

Jedes Nibble wird als 4 binäre Baum-Entscheidungen kodiert. Sieben Vorhersagen werden per logistischem Mixing kombiniert (reine Integer-Festkomma-Arithmetik, eingebettete Sigmoid-Tabellen — kein Float, deterministisch auf jeder Plattform), verfeinert durch zwei APM/SSE-Stufen. Der Decoder spielt das identische Modell vorwärts nach: bijektiv mit 4 Byte Payload-Header (Byte-Anzahl). Kein Suffix-Array-Bau mehr. Die Tabellengrößen sind für Dateien im 100-MB-Bereich ausgelegt (~300 MB Modellspeicher).

## Vergleich

Daten unter https://github.com/bastie/compression-corpus

### enwik8

| Kompressor | Version | Parameter  | Größe in Bytes |     % | Zeit     | Kommentar          |
| ---------- | ------- | ---------- | -------------- | ----- | -------- | ------------------ |
| ben        |    0.50 | -T 1       |   *22.592.372* | 22.59 |  2:13.39 | nbcm, 2. Platz     |
| ben        |    0.51 | -T 1       |    22.592.385  | 22.59 |  3:48.78 | nbcmbf             |
| ben        |    0.51 | -T 8       |    25.043.401  | 25.04 |  0:47.46 | nbcmbf             |
| ben        |    0.52 | -T 1 --gpu |   *22.592.372* | 22.59 |  1:06.93 | nbcm, GPU, bitidentisch zur CPU |
| brotli     |   1.2.0 | -Zkf       |    25.742.001  | 25.74 |  2:30.86 |                    |
| bzip2      |   1.0.8 | -9zkf      |    29.008.758  | 29.01 | *0:04.75*|                    |
| gzip       |     479 | -9kf       |    36.475.811  | 36.48 |**0:03.52** | schnell          |
| xz         |   5.8.2 | -ekfT 1    |    24.831.656  | 24.83 |  0:40.77 |                    |
| zopfli     |   1.0.3 | --i100     |    34.955.165  | 34.96 | 10:10.79 |                    |
| zpaq       |    7.15 | -m5        |  **19.625.015**| 19.63 |  4:32.29 | am besten, 12 Threads |
| zstd       |   1.5.7 | -k19f      |    26.944.227  | 26.94 |  0:41.83 |                    |

>Hinweis: be42 erreicht zpaq (noch) nicht, ist aber besser als alle übrigen — allerdings nur auf Textdaten.

### canterbury

| Kompressor | Version | Parameter | Größe in Bytes |     % | Zeit     | Kommentar          |
| ---------- | ------- | --------- | -------------- | ----- | -------- | ------------------ |
| ben        |    0.50 | -T 1      |       553.942 |  |  0:01.66 | nbcm                    |
| ben        |    0.51 |           |       547.959 |  |  0:00.79 | --blocksize 1           |
| brotli     |   1.2.0 | -Zkf      |       495.485 |  |  0:03.73 |                         |
| bzip2      |   1.0.8 | -9zkf     |       568.342 |  |**0:00.13** | schnell               |
| gzip       |     479 | -9kf      |       730.003 |  | *0:00.50* |                        |
| xz         |   5.8.2 | -ekfT 1   |      *484.656* |  | 0:01.07 |                         |
| zopfli     |   1.0.3 | --i100    |       668.429 |  |  0:24.26 |                         |
| zpaq       |    7.15 | -m5       |     **363.141** |  |0:07.62 | am besten, 12 Threads   |
| zstd       |   1.5.7 | -k19f     |       511.745 |  |  0:00.71 |                         |

### silesia

| Kompressor | Version | Parameter | Größe in Bytes |     % | Zeit     | Kommentar          |
| ---------- | ------- | --------- | -------------- | ----- | -------- | ------------------ |
| ben        |    0.50 | -T 1      |    53.855.592 |  |  5:15.66 | nbcm                    |
| ben        |    0.51 |           |    51.875.294 |  |  2:24.44 |                         |
| brotli     |   1.2.0 | -Zkf      |    49.924.566 |  |  5:08.63 |                         |
| bzip2      |   1.0.8 | -9zkf     |    54.535.546 |  |**0:11.59** | schnell               |
| gzip       |     479 | -9kf      |    67.653.762 |  | *0:12.61* |                        |
| xz         |   5.8.2 | -ekfT 1   |   *48.928.248* |  | 1:09.15 |                         |
| zopfli     |   1.0.3 | --i100    |    64.691.382 |  | 39:34.10 |                         |
| zpaq       |    7.15 | -m5       |  **40.199.494** |  |2:52.25 | am besten, 12 Threads   |
| zstd       |   1.5.7 | -k19f     |    52.854.383 |  |  0:22.31 |                         |


# Abhängigkeiten

**Keine Abhängigkeiten** für die be42-Bibliothek.

Das CLI-Werkzeug *ben* benötigt *swift-argument-parser* und *be42*.

# Lizenz

Apache License Version 2.0

# Version

**0.52.0**

Neuer Schalter `--gpu` (Katalog Nr. 58): Metal-beschleunigte Suffix-Sortierung auf Apple Silicon via MPSGraph-ArgSort — **die Ausgabe bleibt bitidentisch zum CPU-Pfad**, der Schalter ist reine Geschwindigkeit wie `--unsafe`:

1. je Verdopplungsrunde ersetzt EIN GPU-ArgSort über gepackte `Int64`-Schlüssel (`rank << 32 | rank2`) die beiden stabilen Counting-Sorts; die Rangvergabe hängt nur von Schlüssel-GLEICHHEIT benachbarter Elemente ab, Sortier-Stabilität ist für die Rang-Evolution deshalb irrelevant — ein instabiler GPU-Sort liefert per Konstruktion das identische Ergebnis
2. der einzige stabilitäts-sensitive Punkt ist der finale Tiebreak (identische Rotationen bei periodischen Eingaben — der BWT-Index hängt daran): das finale Suffix-Array wird darum immer aus den finalen Rängen mit einem stabilen CPU-Counting-Sort normalisiert (Ordnung = Rang, dann Index) — exakt die CPU-Semantik
3. Unified Memory: die CPU schreibt die Schlüssel direkt in einen `storageModeShared`-Puffer, den die GPU sortiert — keine Transferkopien; der sequenzielle Rang-Scan bleibt auf der CPU
4. die Verfügbarkeit wird einmalig zur Laufzeit geprüft (Metal-Device + Korrektheit des Int64-ArgSort inkl. Schlüsseln oberhalb von 32 Bit); bei Fehlschlag oder unterhalb von ~1 Mi Nibbles fällt der Code transparent auf die CPU zurück — `--gpu` ändert nie die Ausgabe, die Dekompression sortiert nicht und ist unberührt. Hinweis: der GPU-Pfad braucht ~16 zusätzliche Bytes RAM je Eingabe-Byte für den Schlüsselpuffer je parallelem Block

Gemessen auf enwik8 (nbcm, 1 Thread): **1:06,93 statt 2:13,65 Gesamtzeit — 2,0× schneller**; CPU-Rechenzeit 42,98 s statt 130,96 s (Faktor 3,0), die CPU ist während der GPU-Sortierung teilweise frei (68 % Auslastung) und steht damit parallelen Blöcken zur Verfügung. Der befürchtete MPSGraph-Overhead pro Runde frisst den Gewinn nicht auf.

**0.51.0**

Neuer Standard-Algorithmus *nbcmbf* (0x06): *nbcmb* plus ein bijektiver **Wettbewerb** von Vorverarbeitungen je Block (Katalog Nr. 53 + 54), zielt auf Binärdaten — der Markov-Ketten-/Geburtstagsparadox-Kern und die Block-/Parallel-Maschinerie bleiben unangetastet:

1. **Wrapping-Delta-Filter** (Stride 1/2/4/8, `&-`/`&+`, exakt umkehrbar): glättet Arrays numerischer Werte, damit die Permutationsblöcke länger und geburtstags-günstiger werden
2. **Nibble-Planarisierung**: erst alle High-Nibbles, dann alle Low-Nibbles — trennt Struktur (High) vom Rauschen (Low), BEVOR die BWT den Kontext bildet; gemessen am Zielfall 32-Bit-Zähler+Rauschen: −33 %
3. **Wettbewerb statt Heuristik**: je Block werden bis zu vier Varianten (ohne / Delta / Planar / beides; Delta-Stride per deterministischer Integer-Entropie-Schätzung vorausgewählt — kein Float, plattformidentische Ausgabe) TATSÄCHLICH komprimiert, die kleinste gewinnt. Per Konstruktion nie schlechter als *nbcmb* außer 1 Byte je Block. Eine Heuristik allein verschlechterte Text gemessen um bis zu +56 % — darum entscheidet die reale Ausgabegröße
4. safe/unsafe: alle neuen Hot Loops existieren in beiden Varianten (Arrays vs. rohe Pointer), Auswahl über `--unsafe`, bitidentische Ausgabe durch Tests erzwungen; Kompressionskosten bis zu 4 Blockkompressionen (Blöcke laufen weiter parallel), Dekompressionsgeschwindigkeit unverändert (es wird exakt eine Variante dekodiert)

Alle Ströme seit 0.42 bleiben dekomprimierbar (*nbcmb* behält Byte 0x05, unverändert).

**0.50.0** (Speed-Branch)

Speed-Paket 2, Ausgabe bleibt bitidentisch:

1. `--unsafe`: pointerbasierte Hot Loops für den Coder (Modelltabellen als rohe Pointer, keine Bounds-Checks, keine COW-Prüfungen). Safe- und Unsafe-Implementierung stehen nebeneinander — die Nutzerin/der Nutzer entscheidet über den Sicherheits-Kompromiss. Ein Test erzwingt bitidentische Ausgabe und Kreuz-Dekodierung zwischen beiden Varianten
2. die Nibble-BWT-Vorwärts-/Rückwärts-Transformation nutzt jetzt auch im Standardpfad Buffer-Pointer und ein Int32-LF-Mapping

**0.49.0** (Speed-Branch)

Erstes Speed-Paket, Ausgabe bleibt bitidentisch:

1. der Suffix-Array-Bau (die dominante Kostenstelle) arbeitet jetzt auf Int32-Arrays mit Buffer-Pointern im Counting-Sort — halbe Speicherbandbreite, keine Bounds-Checks im Hot Loop
2. *nbcmb*-Blöcke werden parallel komprimiert UND dekomprimiert (`--threads`/`-T`, 0 = Anzahl CPU-Kerne); das längenprefixierte Blockformat macht beide Seiten trivial parallelisierbar. RAM beachten: der Suffix-Array-Bau braucht ~36 Bytes je Eingabe-Byte je parallelem Block — kleinere `--blocksize` erlaubt mehr Parallelität

**0.48.0**

Neuer Standard-Algorithmus *nbcmb* (0x05): *nbcm* im Block-Modus. Die Datei wird in unabhängige, längenprefixierte Blöcke geteilt, jeder mit eigener BWT, eigenem Modell und eigenem Range-Coder-Strom. Das macht enwik9 (1 GB) überhaupt erst möglich (ein Suffix-Array über die ganze Datei bräuchte ~50 GB RAM), hält die Suffix-Array-Arbeitsmengen cache-freundlich (enwik8: 2:16 statt 2:51) und bereitet parallele Kompression UND Dekompression vor — jeder Block ist eigenständig dekodierbar. Gemessene Blockkosten auf enwik8: 16-MiB-Blöcke verlieren ~2 Prozentpunkte Ratio gegenüber einem Einzelblock — die globale BWT-Kontextbündelung wiegt schwer. Darum ist die Blockgröße über `--blocksize` wählbar (MiB, Standard 64). *nbcm*-Ströme (0x04) bleiben dekomprimierbar.

**0.47.0**

Neuer Standard-Algorithmus *nbcm* (nibble.bwt.chain.mixing, 0x04): der Markov-Ketten-/Geburtstagsparadox-Kern bleibt unangetastet — dieselben Permutationsblöcke, Exclusion-Ketten und Kontexte wie *nbmec*. Jede Kontextwahrscheinlichkeit ist jetzt ein PAAR aus schnell und langsam adaptierender Statistik, kombiniert durch einen kleinen gelernten Mixer je Slot (Katalog Nr. 44), verfeinert durch eine APM/SSE-Stufe je Ereignisklasse (Nr. 35). Nichts friert ein, beide Zeitskalen adaptieren dauerhaft. 22,59 % auf enwik8, die Ausgabe ist durch xz nicht weiter komprimierbar. Zwei weitere Schritte (Bit-Historie je Slot, Vor-Nibble-Konditionierung) wurden gemessen und verworfen — die Permutationsstruktur trägt diese Information bereits.

Ebenfalls neu: *ncmm* (nibble.context.mixing.match, 0x03) — Context-Mixing ohne BWT (Ordnungen 0–6, Wortmodell, Sparse-Kontexte, Match-Modell, Hash-Prüfsummen; siehe docs/implizite-informationen.md). Erreicht 24,75 % auf enwik8; vorerst geparkt, bleibt dekodierbar. Alle Algorithmen seit 0.42 bleiben über das Algorithmus-Byte des Containers dekomprimierbar.

**0.43.0**

Neuer Standard-Algorithmus *nbmec* (nibble.bwt.markov.exclusion.cabac): adaptive binäre Exclusion-Kodierung der Permutationsstruktur. Auf einem gemischten Quelltext-/Text-Korpus schlägt er bereits zlib und lzma und liegt nahe an bzip2 — die enwik8-Zahlen in der Vergleichstabelle oben stammen noch von 0.42 (*nbbmr*) und stehen zur Neumessung an. Mit 0.42 komprimierte Dateien bleiben dekomprimierbar (Algorithmus-Byte im Container-Header).

**0.42.0**

Erste öffentliche Version, vielleicht der 42. Versuch einer funktionierenden Implementierung. Besser als gzip.
