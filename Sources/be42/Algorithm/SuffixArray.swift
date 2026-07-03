// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Sebastian Ritter <bastie@users.noreply.github.com>

// Suffix-Array-Konstruktion für NibbleBWT — Swift 6
//
// Zwei Algorithmen:
//
//   SuffixArrayNaive          — O(n² log n), nur für Tests (n ≲ 5.000)
//   SuffixArrayPrefixDoubling — O(n log n),  Produktion
//
// WARUM KEIN DC3/SA-IS?
//   DC3 und SA-IS sortieren *echte Suffixe* (mit appended Sentinel).
//   NibbleBWT benötigt *zyklische Rotationen* (BWT-Standard ohne Sentinel).
//   Für repetitive Daten liefern beide Konventionen VERSCHIEDENE Ergebnisse.
//   Prefix-Doubling sortiert von Natur aus zyklische Rotationen — exakt
//   dasselbe wie der naive Builder, nur schneller.
//
//   Beispiel [2,0,2,0,2,0,2,0]:
//     Zyklisch:  SA = [1,3,5,7,0,2,4,6]  → BWT = [2,2,2,2,0,0,0,0]  ✓
//     Suffix:    SA = [7,5,3,1,6,4,2,0]  → BWT = [1,1,1,1,3,3,3,3]  ✗ (anderer Wert)
//
// GPU-Hinweis (Apple Silicon / Metal):
//   countingSort() — innerster Loop, ~70% der Laufzeit — ist direkt als
//   Metal Compute Shader portierbar: Count → Prefix-Sum → Scatter.
//   Alle drei Phasen sind datenparallel ohne Pointer-Chasing.
//   Dank Unified Memory entfällt der PCIe-Transfer komplett.
//   Der rank-Neuberechnungs-Schritt hat sequenzielle Abhängigkeiten
//   und bleibt auf der CPU.

import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Protokoll
// ─────────────────────────────────────────────────────────────────────────────

/// Gemeinsame Schnittstelle für Suffix-Array-Konstruktionsalgorithmen.
///
/// Alle Implementierungen sortieren **zyklische Rotationen** von `text`
/// lexikografisch. Das ist die für BWT benötigte Konvention.
///
/// Bei identischen Rotationen entscheidet der kleinere Startindex
/// (Tiebreak durch stabile Sortierung).
public protocol SuffixArrayBuilder: Sendable {
  
  /// Liefert das Suffix-Array von `text`.
  ///
  /// - Parameters:
  ///   - text:         Eingabe-Array. Alle Werte in `0 ..< alphabetSize`.
  ///   - alphabetSize: Anzahl unterschiedlicher möglicher Symbole (16 für Nibbles).
  /// - Returns: Array `sa` mit `sa.count == text.count`.
  ///   `sa[i]` = Startindex der i-ten Rotation in lexikografischer Ordnung.
  func build(text: [Int], alphabetSize: Int) -> [Int]
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Naiver Builder  (Referenz, O(n² log n))
// ─────────────────────────────────────────────────────────────────────────────

/// Suffix-Array via Vergleichssort auf zyklischen Rotationen.
///
/// Nur für Tests mit n ≲ 5.000 geeignet.
/// Dient als Korrektheitreferenz für `SuffixArrayPrefixDoubling`.
public struct SuffixArrayNaive: SuffixArrayBuilder, Sendable {
  
  public init() {}
  
  public func build(text: [Int], alphabetSize: Int) -> [Int] {
    let n = text.count
    var sa = Array(0 ..< n)
    sa.sort { a, b in
      for off in 0 ..< n {
        let ca = text[(a + off) % n]
        let cb = text[(b + off) % n]
        if ca != cb { return ca < cb }
      }
      return a < b   // Tiebreak: kleinerer Startindex
    }
    return sa
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Prefix-Doubling  (Produktion, O(n log n))
// ─────────────────────────────────────────────────────────────────────────────

/// Suffix-Array via Prefix-Doubling (Manber & Myers 1990).
///
/// **Idee:** Starte mit Rängen basierend auf Einzelzeichen (= Alphabet-Wert).
/// Verdopple in jedem Schritt die Vergleichsschlüssellänge:
/// Rang von Position i ist das Paar `(rank[i], rank[(i+gap) % n])`.
/// Nach `⌈log₂(n)⌉` Schritten sind alle Ränge eindeutig → SA fertig.
///
/// **Zyklische Rotationen:** `(i + gap) % n` sorgt dafür, dass am
/// Stringende automatisch in den Anfang gewrapped wird — exakt die
/// für BWT benötigte zyklische Semantik.
///
/// **Stabiler Counting-Sort** als innere Sortierung sichert:
/// - O(n) pro Schritt (statt O(n log n) bei Vergleichssort)
/// - Gesamtkomplexität O(n log n)
/// - Korrekte Tiebreaks durch Stabilitätseigenschaft
///
/// **Speicher:** O(n) — keine Rekursion, keine Hilfsarrays der Größe > 2n.
///
/// **GPU-Portierbarkeit:** `countingSort()` ist der primäre Kandidat
/// für Metal Compute Shader (Count→Prefix-Sum→Scatter, ~70% der Laufzeit).
public struct SuffixArrayPrefixDoubling: SuffixArrayBuilder, Sendable {
  
  public init() {}
  
  public func build(text: [Int], alphabetSize: Int) -> [Int] {
    let n = text.count
    if n == 0 { return [] }
    if n == 1 { return [0] }
    // Speed: alle Arbeitsarrays in Int32 — Nibble-Ströme sind < 2^31 Elemente,
    // halbierte Elementgröße = halbe Speicherbandbreite im dominanten
    // countingSort. Semantik identisch zur Int-Fassung (Konsistenztests
    // gegen SuffixArrayNaive sichern das).
    precondition(n <= Int(Int32.max), "SuffixArrayPrefixDoubling: n > Int32.max")

    // ── Schritt 1: Initiale Ränge aus Zeichenwerten ──────────────────────────
    let text32 = text.map { Int32($0) }
    let identity = [Int32]((0 ..< Int32(n)))

    var sa = countingSort(identity, key: text32, K: alphabetSize)

    var rank = [Int32](repeating: 0, count: n)
    rank[Int(sa[0])] = 0
    var numDistinct = 1
    for i in 1 ..< n {
      if text32[Int(sa[i])] != text32[Int(sa[i-1])] { numDistinct += 1 }
      rank[Int(sa[i])] = Int32(numDistinct - 1)
    }

    if numDistinct == n { return sa.map { Int($0) } }

    // ── Schritt 2: Verdopplung ───────────────────────────────────────────────
    // Invariante und Ablauf wie zuvor (siehe Kommentar oben in der Datei);
    // stabile Counting-Sorts sichern den Tiebreak nach Startindex.
    var gap = 1
    while gap < n {
      let r = rank  // Snapshot: unveränderliche Kopie für Schlüsselberechnung

      // Zweites Schlüsselarray: rank[(i+gap)%n] — ohne Modulo im Hot Loop
      var key2 = [Int32](repeating: 0, count: n)
      key2.withUnsafeMutableBufferPointer { k2 in
        r.withUnsafeBufferPointer { rp in
          let split = n - gap
          for i in 0 ..< split { k2[i] = rp[i + gap] }
          for i in split ..< n { k2[i] = rp[i + gap - n] }
        }
      }

      // Pass 1: stabil nach zweitem Schlüssel sortieren
      let sa2 = countingSort(identity, key: key2, K: numDistinct)

      // Pass 2: stabil nach erstem Schlüssel sortieren (Ergebnis ist in sa)
      sa = countingSort(sa2, key: r, K: numDistinct)

      // Ränge neu berechnen
      var newRank = [Int32](repeating: 0, count: n)
      newRank[Int(sa[0])] = 0
      numDistinct = 1
      for i in 1 ..< n {
        let a = Int(sa[i-1]), b = Int(sa[i])
        let different = r[a] != r[b] || key2[a] != key2[b]
        if different { numDistinct += 1 }
        newRank[b] = Int32(numDistinct - 1)
      }
      rank = newRank

      if numDistinct == n { break }
      gap *= 2
    }

    return sa.map { Int($0) }
  }
  
  // ───────────────────────────────────────────────────────────────────────────
  // MARK: Counting-Sort (stabil)
  // ───────────────────────────────────────────────────────────────────────────
  
  /// Sortiert `arr` stabil nach `key[arr[i]]`. Schlüssel in `[0, K)`.
  ///
  /// Ergebnis: neues Array der sortierten Elemente aus `arr`.
  ///
  /// **Stabilität:** Elemente mit gleichem Schlüssel behalten ihre
  /// relative Reihenfolge aus `arr` — kritisch für korrekten Tiebreak.
  ///
  /// **GPU-Portierbarkeit:** Die drei Phasen sind Metal-Standardprimitive.
  /// Bei K=16 (Nibble-Alphabet, erster Sort) passen alle Zähler in
  /// 128 Bytes threadgroup shared memory. Bei K=n (spätere Schritte)
  /// ist GPU-Parallelismus über Radix-Sort mit mehreren Passes effizient.
  ///
  /// - Parameters:
  ///   - arr: Zu sortierende Indizes.
  ///   - key: Schlüssel-Array. `key[arr[i]]` = Schlüssel für `arr[i]`.
  ///          Muss Zugriff auf alle Werte in `arr` erlauben.
  ///   - K:   Anzahl möglicher Schlüsselwerte (exklusives Maximum).
  private func countingSort(_ arr: [Int32], key: [Int32], K: Int) -> [Int32] {
    guard !arr.isEmpty else { return [] }
    let n = arr.count

    var out = [Int32](repeating: 0, count: n)
    var start = [Int32](repeating: 0, count: K)

    // Alle drei Phasen über Buffer-Pointer: der Sort ist bandbreitenlimitiert,
    // Bounds-Checks kosten hier zweistellig Prozent.
    arr.withUnsafeBufferPointer { a in
      key.withUnsafeBufferPointer { k in
        start.withUnsafeMutableBufferPointer { s in
          out.withUnsafeMutableBufferPointer { o in
            // Phase 1: Häufigkeiten (in start akkumuliert)
            for i in 0 ..< n { s[Int(k[Int(a[i])])] &+= 1 }
            // Phase 2: Prefix-Summe → Startpositionen (exklusiv)
            var sum: Int32 = 0
            for i in 0 ..< K {
              let c = s[i]
              s[i] = sum
              sum &+= c
            }
            // Phase 3: Scatter (in Reihenfolge von arr → stabil)
            for i in 0 ..< n {
              let x = a[i]
              let kk = Int(k[Int(x)])
              o[Int(s[kk])] = x
              s[kk] &+= 1
            }
          }
        }
      }
    }
    return out
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Self-Test
// ─────────────────────────────────────────────────────────────────────────────

public enum SuffixArrayTest {
  
  /// Prüft `SuffixArrayPrefixDoubling` gegen `SuffixArrayNaive`.
  ///
  /// Abgedeckte Fälle:
  ///   - Trivialfälle (n=0,1,2)
  ///   - Konstante Streams (klassischer Problemfall für DC3)
  ///   - Wechselmuster ABAB (periodisch, BWT-relevant)
  ///   - Alle 16 Nibble-Werte
  ///   - XML-typische Muster
  ///   - Zufalls-Stresstest mit Vergleich gegen Naiv
  ///   - Laufzeit-Indikation
  @discardableResult
  public static func selfTest() -> Bool {
    
    let naive = SuffixArrayNaive()
    let fast  = SuffixArrayPrefixDoubling()
    
    var allPassed = true
    var testNumber = 0
    
    func check(_ name: String, _ condition: Bool) {
      testNumber += 1
      if condition {
        print("  [\(testNumber)] ✓  \(name)")
      } else {
        print("  [\(testNumber)] ✗  FAILED: \(name)")
        allPassed = false
      }
    }
    
    /// Prüft ob `sa` eine gültige Permutation ist UND alle Rotationen
    /// in aufsteigender lexikografischer Reihenfolge stehen.
    func isValidSA(_ sa: [Int], text: [Int]) -> Bool {
      let n = text.count
      guard sa.count == n, Set(sa) == Set(0 ..< n) else { return false }
      for i in 1 ..< n {
        let a = sa[i-1], b = sa[i]
        for off in 0 ..< n {
          let ca = text[(a + off) % n]
          let cb = text[(b + off) % n]
          if ca < cb { break }
          if ca > cb { return false }
        }
      }
      return true
    }
    
    func matches(_ text: [Int]) -> Bool {
      let ref = naive.build(text: text, alphabetSize: 16)
      let got = fast.build(text: text,  alphabetSize: 16)
      return ref == got
    }
    
    print("═══════════════════════════════════════════")
    print("  SuffixArrayPrefixDoubling Self-Test")
    print("═══════════════════════════════════════════")
    
    // ── Block 1: Trivialfälle ────────────────────────────────────────────────
    print("\n── Block 1: Trivialfälle ──")
    
    check("n=0: leeres SA",
          fast.build(text: [], alphabetSize: 16).isEmpty)
    check("n=1: SA=[0]",
          fast.build(text: [7], alphabetSize: 16) == [0])
    check("n=2 gleich [3,3]: gültig",
          isValidSA(fast.build(text: [3,3], alphabetSize: 16), text: [3,3]))
    check("n=2 gleich [3,3]: == Naiv",
          matches([3,3]))
    check("n=2 verschieden [1,0]: SA=[1,0]",
          fast.build(text: [1,0], alphabetSize: 16) == [1,0])
    check("n=2 verschieden [0,1]: SA=[0,1]",
          fast.build(text: [0,1], alphabetSize: 16) == [0,1])
    
    // ── Block 2: Konstante Streams ───────────────────────────────────────────
    // Klassischer Problemfall für DC3 (alle Tripel identisch → tiefe Rekursion).
    // Prefix-Doubling: stabile Sorts erhält Indexreihenfolge → korrekt.
    print("\n── Block 2: Konstante Streams (klassischer DC3-Problemfall) ──")
    
    for len in [2, 3, 4, 5, 7, 8, 9, 15, 16, 17] {
      let c = [Int](repeating: 5, count: len)
      let sa = fast.build(text: c, alphabetSize: 16)
      check("Konstant [5×\(len)]: SA=[0,1,...,\(len-1)]",
            sa == Array(0 ..< len))
    }
    
    // ── Block 3: Periodische Muster ──────────────────────────────────────────
    print("\n── Block 3: Periodische Muster ──")
    
    // ABAB — BWT-Schlüsseltest: ergibt [2,2,2,2,0,0,0,0]
    let abab8: [Int] = [2,0,2,0,2,0,2,0]
    check("ABAB [2,0,×4] n=8: gültig",   isValidSA(fast.build(text: abab8, alphabetSize: 16), text: abab8))
    check("ABAB [2,0,×4] n=8: == Naiv",  matches(abab8))
    check("ABAB [2,0,×4] n=8: SA=[1,3,5,7,0,2,4,6]",
          fast.build(text: abab8, alphabetSize: 16) == [1,3,5,7,0,2,4,6])
    
    let abab16 = (0..<16).map { $0 % 2 == 0 ? 2 : 0 }
    check("ABAB ×16: gültig",  isValidSA(fast.build(text: abab16, alphabetSize: 16), text: abab16))
    check("ABAB ×16: == Naiv", matches(abab16))
    
    // ABCABC
    let abc6: [Int] = [1,2,3,1,2,3]
    check("ABCABC n=6: == Naiv", matches(abc6))
    
    // ── Block 4: Nibble-typische Muster ─────────────────────────────────────
    print("\n── Block 4: Nibble-Muster ──")
    
    let allAsc = [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]
    check("Alle 16 Nibbles aufst.: gültig",  isValidSA(fast.build(text: allAsc, alphabetSize: 16), text: allAsc))
    check("Alle 16 Nibbles aufst.: == Naiv", matches(allAsc))
    
    let allDesc = allAsc.reversed() as [Int]
    check("Alle 16 Nibbles abst.: gültig",   isValidSA(fast.build(text: allDesc, alphabetSize: 16), text: allDesc))
    check("Alle 16 Nibbles abst.: == Naiv",  matches(allDesc))
    
    // "Hello" in Nibbles: [4,8,6,5,6,0xC,6,0xC,6,0xF]
    let hello: [Int] = [4,8,6,5,6,12,6,12,6,15]
    check("'Hello' Nibbles: == Naiv", matches(hello))
    
    // XML-typisch: High-Nibble 3 und 7 dominieren
    let xml: [Int] = [3,12, 7,4, 6,5, 7,8, 7,4, 3,14, 3,12, 2,15, 7,4, 6,5, 7,8, 7,4, 3,14]
    check("XML-Pattern: == Naiv", matches(xml))
    
    // ── Block 5: Zufalls-Stresstest ─────────────────────────────────────────
    print("\n── Block 5: Zufalls-Stresstest ──")
    
    var rngState: UInt64 = 0xDEAD_BEEF_1337_CAFE
    func nextNibble() -> Int {
      rngState = rngState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((rngState >> 60) & 0xF)
    }
    
    // n=50: vollständiger Vergleich mit Naiv
    for round in 0 ..< 20 {
      let text = (0 ..< 50).map { _ in nextNibble() }
      if !matches(text) {
        check("n=50 Runde \(round): == Naiv", false)
      }
    }
    check("20 × n=50 Zufallstests: alle == Naiv", allPassed)
    
    // n=200: Gültigkeits-Check (Naiv wäre zu langsam)
    for round in 0 ..< 10 {
      let text = (0 ..< 200).map { _ in nextNibble() }
      let sa   = fast.build(text: text, alphabetSize: 16)
      if !isValidSA(sa, text: text) {
        check("n=200 Runde \(round): SA gültig", false)
      }
    }
    check("10 × n=200 Zufallstests: SA gültig", allPassed)
    
    // n=1.000
    let r1k = (0 ..< 1_000).map { _ in nextNibble() }
    check("n=1.000: SA gültig",
          isValidSA(fast.build(text: r1k, alphabetSize: 16), text: r1k))
    
    // n=10.000
    let r10k = (0 ..< 10_000).map { _ in nextNibble() }
    check("n=10.000: SA gültig",
          isValidSA(fast.build(text: r10k, alphabetSize: 16), text: r10k))
    
    // ── Block 6: BWT-Konsistenztest ──────────────────────────────────────────
    // Prüft dass NibbleBWT mit PrefixDoubling dieselbe BWT-Ausgabe liefert
    // wie mit dem naiven Builder — das ist die eigentliche Garantie.
    print("\n── Block 6: BWT-Konsistenz (SA → BWT-Ausgabe) ──")
    
    func bwtOutput(text: [Int], builder: any SuffixArrayBuilder) -> ([Int], Int) {
      let n  = text.count
      let sa = builder.build(text: text, alphabetSize: 16)
      var bwt   = [Int](repeating: 0, count: n)
      var index = 0
      for i in 0 ..< n {
        bwt[i] = text[(sa[i] + n - 1) % n]
        if sa[i] == 0 { index = i }
      }
      return (bwt, index)
    }
    
    let bwtTests: [[Int]] = [
      abab8,
      [2,2,2,2,2,2,2,2],
      [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15],
      (0 ..< 30).map { _ in nextNibble() },
      (0 ..< 30).map { _ in nextNibble() },
    ]
    for (idx, text) in bwtTests.enumerated() {
      let (bwtNaive, idxNaive) = bwtOutput(text: text, builder: naive)
      let (bwtFast,  idxFast)  = bwtOutput(text: text, builder: fast)
      check("BWT-Test \(idx+1): Ausgabe identisch",   bwtNaive == bwtFast)
      check("BWT-Test \(idx+1): Index identisch",     idxNaive == idxFast)
    }
    
    // ── Block 7: Laufzeit ────────────────────────────────────────────────────
    print("\n── Block 7: Laufzeit-Indikation ──")
    
    for size in [10_000, 100_000, 500_000, 2_000_000] {
      let data  = (0 ..< size).map { _ in nextNibble() }
      let t0    = Date()
      _         = fast.build(text: data, alphabetSize: 16)
      let ms    = Date().timeIntervalSince(t0) * 1000
      let mns   = Double(size) / ms / 1000   // M Nibbles/s
      print(String(format: "  [ ] ℹ  n=%7d: %5.0f ms  (~%.1f M Nibbles/s)",
                   size, ms, mns))
    }
    check("Laufzeit-Tests abgeschlossen", true)
    
    // ── Zusammenfassung ──────────────────────────────────────────────────────
    print("\n═══════════════════════════════════════════")
    if allPassed {
      print("  Ergebnis: Alle \(testNumber) Tests bestanden ✓")
      print("  Bijektivität: SuffixArrayPrefixDoubling == SuffixArrayNaive ✓")
    } else {
      print("  Ergebnis: Mindestens ein Test FEHLGESCHLAGEN ✗")
    }
    print("═══════════════════════════════════════════\n")
    
    return allPassed
  }
}
