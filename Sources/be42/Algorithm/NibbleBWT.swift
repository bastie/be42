// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Sebastian Ritter <bastie@users.noreply.github.com>

// Burrows-Wheeler-Transform auf Nibble-Ebene — Swift 6
//
// Zweck: Pre-Filter für BEN_BWT.
//
// WICHTIG — Zyklische Rotationen vs. echte Suffixe:
//   Diese Implementierung sortiert ZYKLISCHE ROTATIONEN (kein Sentinel).
//   DC3/SA-IS sortieren echte Suffixe → andere SA für periodische Daten
//   → andere BWT-Ausgabe → inkompatibel mit dieser Inverse-Transform.
//   Der Default-Builder (SuffixArrayPrefixDoubling) sortiert ebenfalls
//   zyklische Rotationen — garantiert konsistente Ergebnisse.
//

// MARK: - Typdefinitionen

public struct NibbleBWTResult: Sendable, Equatable {
  let transformed: [UInt8]
  let index: Int
}

// MARK: - NibbleBWT

public enum NibbleBWT: Sendable {
  
  // Austauschbarer Builder — Standard: PrefixDoubling (O(n log n), korrekt)
  // Für Tests: SuffixArrayNaive() einsetzen
  nonisolated(unsafe) static var builder: any SuffixArrayBuilder = SuffixArrayPrefixDoubling()
  
  // MARK: Vorwärts-Transform
  
  static func transform(_ nibbles: [UInt8]) -> NibbleBWTResult {
    let n = nibbles.count
    if n == 0 { return NibbleBWTResult(transformed: [],      index: 0) }
    if n == 1 { return NibbleBWTResult(transformed: nibbles, index: 0) }
    
    assert(nibbles.allSatisfy { $0 <= 0xF },
           "NibbleBWT: Alle Werte müssen im Bereich 0x0...0xF liegen.")
    
    let text = nibbles.map { Int($0) }
    let sa   = builder.build(text: text, alphabetSize: 16)

    var transformed   = [UInt8](repeating: 0, count: n)
    var originalIndex = 0

    // Speed: Buffer-Pointer, Modulo durch Verzweigung ersetzt
    transformed.withUnsafeMutableBufferPointer { t in
      nibbles.withUnsafeBufferPointer { nb in
        sa.withUnsafeBufferPointer { s in
          for i in 0 ..< n {
            let si = s[i]
            t[i] = nb[si == 0 ? n - 1 : si - 1]
            if si == 0 { originalIndex = i }
          }
        }
      }
    }

    return NibbleBWTResult(transformed: transformed, index: originalIndex)
  }
  
  // MARK: Inverse Transform  (O(n), LF-Mapping)
  
  static func inverseTransform(_ transformed: [UInt8], index: Int) -> [UInt8] {
    let n = transformed.count
    if n == 0 { return [] }
    if n == 1 { return transformed }
    
    var countPerValue = [Int](repeating: 0, count: 16)
    for nibble in transformed { countPerValue[Int(nibble)] += 1 }
    
    var firstOccurrence = [Int](repeating: 0, count: 16)
    var runningSum = 0
    for v in 0 ..< 16 { firstOccurrence[v] = runningSum; runningSum += countPerValue[v] }
    
    var rank = [Int](repeating: 0, count: 16)
    var lf   = [Int32](repeating: 0, count: n)   // Int32: halbe Bandbreite
    var result  = [UInt8](repeating: 0, count: n)

    // Speed: Buffer-Pointer — LF-Mapping und Rücklauf sind Random-Access-lastig
    transformed.withUnsafeBufferPointer { t in
      lf.withUnsafeMutableBufferPointer { l in
        rank.withUnsafeMutableBufferPointer { r in
          for i in 0 ..< n {
            let v = Int(t[i])
            l[i] = Int32(firstOccurrence[v] + r[v])
            r[v] += 1
          }
        }
        result.withUnsafeMutableBufferPointer { res in
          var current = index
          for i in stride(from: n - 1, through: 0, by: -1) {
            res[i]  = t[current]
            current = Int(l[current])
          }
        }
      }
    }
    return result
  }
  
  // MARK: Self-Test
  
  @discardableResult
  public static func selfTest() -> Bool {
    var allPassed = true
    var testNumber = 0
    
    func check(_ name: String, _ condition: Bool) {
      testNumber += 1
      if condition { print("  [\(testNumber)] ✓  \(name)") }
      else         { print("  [\(testNumber)] ✗  FAILED: \(name)"); allPassed = false }
    }
    
    func roundtrip(_ nibbles: [UInt8]) -> Bool {
      let r = transform(nibbles)
      return inverseTransform(r.transformed, index: r.index) == nibbles
    }
    
    func maxRun(_ a: [UInt8], of v: UInt8) -> Int {
      var best = 0, cur = 0
      for x in a { cur = x == v ? cur + 1 : 0; if cur > best { best = cur } }
      return best
    }
    
    print("═══════════════════════════════════════════")
    print("  NibbleBWT Self-Test  (Builder: \(type(of: builder)))")
    print("═══════════════════════════════════════════")
    
    print("\n── Block 1: Trivialfälle ──")
    let empty = transform([])
    check("Leerer Stream: leer",    empty.transformed.isEmpty)
    check("Leerer Stream: index=0", empty.index == 0)
    check("Leerer Stream: Roundtrip", roundtrip([]))
    let single = transform([0xA])
    check("Einzelnes 0xA: unverändert", single.transformed == [0xA])
    check("Einzelnes 0xA: index=0",     single.index == 0)
    check("Einzelnes 0xA: Roundtrip",   roundtrip([0xA]))
    
    print("\n── Block 2: Konstante Streams ──")
    for len in [2, 3, 4, 8, 16] {
      let run = [UInt8](repeating: 2, count: len)
      let r   = transform(run)
      check("Run [2×\(len)]: transformed==input", r.transformed == run)
      check("Run [2×\(len)]: Roundtrip",          roundtrip(run))
    }
    
    print("\n── Block 3: ABAB-Muster ──")
    let abab: [UInt8] = [2,0,2,0,2,0,2,0]
    let altR = transform(abab)
    check("ABAB: BWT=[2,2,2,2,0,0,0,0]", altR.transformed == [2,2,2,2,0,0,0,0])
    check("ABAB: index=4",                altR.index == 4)
    check("ABAB: Roundtrip",              roundtrip(abab))
    let abab16 = (0..<16).map { UInt8($0 % 2 == 0 ? 2 : 0) }
    check("ABAB×16: Roundtrip",           roundtrip(abab16))
    let r16 = transform(abab16)
    check("ABAB×16: perfekt geclustert",
          r16.transformed.prefix(8).allSatisfy { $0 == 2 } &&
          r16.transformed.suffix(8).allSatisfy { $0 == 0 })
    
    print("\n── Block 4: ASCII / XML ──")
    let hello: [UInt8] = [4,8,6,5,6,0xC,6,0xC,6,0xF]
    check("'Hello': Roundtrip", roundtrip(hello))
    check("'Hello': 6er geclustert",
          maxRun(transform(hello).transformed, of: 6) >= 2)
    
    let xml: [UInt8] = [3,0xC, 7,4, 6,5, 7,8, 7,4, 3,0xE,
                        3,0xC, 2,0xF, 7,4, 6,5, 7,8, 7,4, 3,0xE]
    check("XML: Roundtrip", roundtrip(xml))
    check("XML: 3er geclustert", maxRun(transform(xml).transformed, of: 3) >= 2)
    check("XML: 7er geclustert", maxRun(transform(xml).transformed, of: 7) >= 2)
    
    print("\n── Block 5: Vollständiges Alphabet ──")
    let allV: [UInt8] = [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]
    check("16 Werte aufst.: Roundtrip", roundtrip(allV))
    check("16 Werte abst.:  Roundtrip", roundtrip(allV.reversed()))
    
    print("\n── Block 6: Builder-Konsistenz (PrefixDoubling == Naiv) ──")
    let savedBuilder = builder
    let naiveBuilder = SuffixArrayNaive()
    
    let consistencyTests: [[UInt8]] = [
      abab,
      allV,
      [UInt8](repeating: 5, count: 8),
      [UInt8](repeating: 5, count: 9),
    ]
    for (i, tc) in consistencyTests.enumerated() {
      let bwtFast  = transform(tc)
      builder      = naiveBuilder
      let bwtNaive = transform(tc)
      builder      = savedBuilder
      check("Konsistenz Test \(i+1): transformed==",
            bwtFast.transformed == bwtNaive.transformed)
      check("Konsistenz Test \(i+1): index==",
            bwtFast.index == bwtNaive.index)
    }
    
    print("\n── Block 7: Zufalls-Stresstest ──")
    var state: UInt64 = 0xDEAD_BEEF_CAFE_1337
    func nextNibble() -> UInt8 {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return UInt8((state >> 60) & 0xF)
    }
    let rnd500  = (0..<500).map  { _ in nextNibble() }
    check("500 Zufalls-Nibbles: Roundtrip",  roundtrip(rnd500))
    let rnd2000 = rnd500 + (0..<1500).map { _ in nextNibble() }
    check("2000 Zufalls-Nibbles: Roundtrip", roundtrip(rnd2000))
    
    print("\n═══════════════════════════════════════════")
    print(allPassed
          ? "  Ergebnis: Alle \(testNumber) Tests bestanden ✓"
          : "  Ergebnis: Mindestens ein Test FEHLGESCHLAGEN ✗")
    print("═══════════════════════════════════════════\n")
    return allPassed
  }
}
