// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Sebastian Ritter <bastie@users.noreply.github.com>

/*
 * BEN_MEC – Markov-Exclusion-Coder auf Nibble-Ebene
 *
 * Grundidee:
 *   Die Permutations-Blockstruktur (siehe README) wird nicht mehr uniform
 *   kodiert, sondern über adaptive BINÄRE Entscheidungen: für die
 *   wahrscheinlichsten Kandidaten wird kodiert, dass ein Wert es NICHT ist
 *   (Exclusion-Kette), bis der Treffer kommt. Der letzte verbleibende
 *   Kandidat ist implizit und kostet 0 Bit.
 *
 *   Die Markov-Eigenschaft "Wiederholungswahrscheinlichkeit steigt mit der
 *   Permutationslänge" wird adaptiv über Kontexte je Anzahl gesehener
 *   Werte (d) gelernt statt statisch angenommen. Läufe (nach BWT häufig)
 *   erhalten eigene Kontexte je Lauflänge.
 *
 * Pipeline: Bytes → Nibbles → NibbleBWT → adaptiver binärer Range-Coder
 *           (Kandidaten in Move-To-Front-Reihenfolge, Kontexte:
 *            d, Lauflänge, Kettenposition × min(d,4))
 *
 * Eigenschaften:
 *   - vollständig bijektiv: der Decoder führt das identische Modell
 *     vorwärts — jede Modelländerung hängt nur von bereits dekodierten
 *     Symbolen ab
 *   - Ein-Pass, adaptiv: keine Frequenztabellen im Header, kein Tail
 *   - Range-Coder im LZMA-Stil: 32-Bit-Range, 11-Bit-Wahrscheinlichkeiten,
 *     Shift-5-Adaption; Kodierung vorwärts, dadurch beliebige Adaption
 *
 * Format:
 *   [4B nibbleCount BE] [4B bwtIndex BE] [Range-Coder-Strom]
 *
 */

import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Fehlertypen
// ─────────────────────────────────────────────────────────────────────────────

public enum BEN_MECError: Error, CustomStringConvertible, Sendable {
  case invalidData(String)
  case fileTooLarge

  public var description: String {
    switch self {
    case .invalidData(let m): return "Ungültige Daten: \(m)"
    case .fileTooLarge:       return "Datei zu groß (max 2 GB)"
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Konstanten
// ─────────────────────────────────────────────────────────────────────────────

/// Wahrscheinlichkeitsauflösung: 11 Bit → Werte in (0, 2048).
private let kProbBits:  UInt32 = 11
private let kProbTotal: UInt16 = 2048
private let kProbInit:  UInt16 = 1024
/// Adaptionsgeschwindigkeit (empirisch: 5 optimal auf Text-Korpora;
/// 4 adaptiert schneller, verliert aber auf großen Dateien).
private let kMoveBits:  UInt16 = 5
/// Renormalisierungsschwelle des Range-Coders.
private let kTopValue:  UInt32 = 1 << 24

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Range-Encoder (LZMA-Stil, vorwärts)
// ─────────────────────────────────────────────────────────────────────────────

private struct RangeEncoder {

  private var low:       UInt64 = 0
  private var range:     UInt32 = 0xFFFF_FFFF
  private var cache:     UInt8  = 0
  private var cacheSize: UInt64 = 1
  private(set) var output: [UInt8] = []

  /// Kodiert ein Bit mit adaptiver Wahrscheinlichkeit.
  /// `prob` ist die Wahrscheinlichkeit für Bit==0 (in 1/2048).
  mutating func encodeBit(_ prob: inout UInt16, _ bit: Int) {
    let bound = (range >> kProbBits) &* UInt32(prob)
    if bit == 0 {
      range = bound
      prob &+= (kProbTotal &- prob) >> kMoveBits
    } else {
      low &+= UInt64(bound)
      range &-= bound
      prob &-= prob >> kMoveBits
    }
    while range < kTopValue {
      range <<= 8
      shiftLow()
    }
  }

  private mutating func shiftLow() {
    let low32 = UInt32(truncatingIfNeeded: low)
    if low32 < 0xFF00_0000 || low > 0xFFFF_FFFF {
      let carry = UInt8(truncatingIfNeeded: low >> 32)   // 0 oder 1
      output.append(cache &+ carry)
      while cacheSize > 1 {
        output.append(0xFF &+ carry)
        cacheSize &-= 1
      }
      cacheSize = 0
      cache = UInt8(truncatingIfNeeded: low32 >> 24)
    }
    cacheSize &+= 1
    low = UInt64(low32 << 8)
  }

  mutating func flush() {
    for _ in 0..<5 { shiftLow() }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Range-Decoder
// ─────────────────────────────────────────────────────────────────────────────

private struct RangeDecoder {

  private let data:  [UInt8]
  private var pos:   Int
  private var range: UInt32 = 0xFFFF_FFFF
  private var code:  UInt32 = 0

  init(data: [UInt8], startPos: Int) {
    self.data = data
    self.pos  = startPos
    for _ in 0..<5 {
      code = (code << 8) | UInt32(nextByte())
    }
  }

  /// Liest hinter dem Datenende 0-Bytes — robust gegen abgeschnittene
  /// Eingaben (liefert dann falsche Symbole, aber keinen Absturz).
  private mutating func nextByte() -> UInt8 {
    guard pos < data.count else { return 0 }
    let b = data[pos]
    pos &+= 1
    return b
  }

  mutating func decodeBit(_ prob: inout UInt16) -> Int {
    let bound = (range >> kProbBits) &* UInt32(prob)
    let bit: Int
    if code < bound {
      range = bound
      prob &+= (kProbTotal &- prob) >> kMoveBits
      bit = 0
    } else {
      code &-= bound
      range &-= bound
      prob &-= prob >> kMoveBits
      bit = 1
    }
    while range < kTopValue {
      range <<= 8
      code = (code << 8) | UInt32(nextByte())
    }
    return bit
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Markov-Exclusion-Modell
// ─────────────────────────────────────────────────────────────────────────────

/// Gemeinsamer Modellzustand von Encoder und Decoder.
/// Beide Seiten führen exakt dieselben Updates aus → Bijektivität.
private struct MECModel {

  /// Kandidaten-Rangfolge: zuletzt gesehene Werte zuerst (Move-To-Front).
  /// InlineArray (Swift 6.3, SE-0453): 16 Nibble-Werte, zur Compile-Zeit
  /// fest — kein Heap-Objekt, kein ARC. Konsumstellen (Encoder/Decoder)
  /// iterieren über `.indices` statt direkt über das Array (InlineArray
  /// ist bewusst kein Sequence/Collection, siehe docs/geschwindigkeit.md
  /// Nr. 16).
  var mtf: InlineArray<16, UInt8> = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
  /// Bitmaske der im aktuellen Permutations-Block gesehenen Werte.
  var seenMask: UInt16 = 0
  /// Aktuelle Lauflänge (aufeinanderfolgende Wiederholungen bei d==1).
  var runLength: Int = 0

  /// "Wiederholt sich der nächste Wert?" je Anzahl gesehener Werte d (2...15).
  var probRepeat: InlineArray<17, UInt16> = InlineArray<17, UInt16>(repeating: kProbInit)
  /// Wie probRepeat, aber für d==1 je Lauflänge (0...15) — Läufe nach BWT.
  var probRun: InlineArray<16, UInt16> = InlineArray<16, UInt16>(repeating: kProbInit)
  /// Exclusion-Ketten: Kettenposition j (0...14) × min(d, 4). 15*5 = 75.
  var probRepChain: InlineArray<75, UInt16> = InlineArray<75, UInt16>(repeating: kProbInit)
  var probNewChain: InlineArray<75, UInt16> = InlineArray<75, UInt16>(repeating: kProbInit)

  /// Ketten-Kontext: Position in der Kette, konditioniert auf gebuckelte
  /// Blockgröße (d=0 Streamstart, d=1 nach Lauf, d=2,3 kurze Blöcke, 4+ Rest).
  @inline(__always)
  func chainContext(_ j: Int, _ d: Int) -> Int {
    return j + 15 * min(d, 4)
  }

  @inline(__always)
  mutating func moveToFront(_ v: UInt8) {
    guard mtf[0] != v else { return }
    var i = 1
    while mtf[i] != v { i += 1 }
    while i > 0 {
      mtf[i] = mtf[i - 1]
      i -= 1
    }
    mtf[0] = v
  }

  /// Modell-Update nach jedem Symbol — identisch in Encoder und Decoder.
  @inline(__always)
  mutating func update(_ v: UInt8, isRepeat: Bool, d: Int) {
    if isRepeat {
      seenMask  = UInt16(1) << v          // Block endet, neuer Block mit Carry
      runLength = (d == 1) ? runLength + 1 : 0
    } else {
      seenMask |= UInt16(1) << v
      runLength = 0
    }
    moveToFront(v)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – BEN_MEC
// ─────────────────────────────────────────────────────────────────────────────

public enum BEN_MEC {

  // ───────────────────────────────────────────────────────────────────────────
  // MARK: Symbol kodieren/dekodieren
  // ───────────────────────────────────────────────────────────────────────────

  private static func encode(_ v: UInt8, _ model: inout MECModel, _ rc: inout RangeEncoder) {
    let d = model.seenMask.nonzeroBitCount
    let isRepeat = (model.seenMask >> v) & 1 == 1

    // 1. Entscheidung: Wiederholung (beendet Block) oder neuer Wert?
    //    Bei d==0 zwingend neu, bei d==16 zwingend Wiederholung → 0 Bit.
    if d != 0 && d != 16 {
      let bit = isRepeat ? 1 : 0
      if d == 1 {
        rc.encodeBit(&model.probRun[min(model.runLength, 15)], bit)
      } else {
        rc.encodeBit(&model.probRepeat[d], bit)
      }
    }

    // 2. Exclusion-Kette: Kandidaten in MTF-Reihenfolge; je Kandidat ein
    //    Bit "ist er es (NICHT)?" — der letzte Kandidat ist implizit.
    let total = isRepeat ? d : 16 - d
    var j = 0
    // InlineArray ist kein Sequence/Collection → über .indices iterieren
    // statt direkt über das Array (siehe Deklaration von `mtf` oben).
    for idx in model.mtf.indices {
      let c = model.mtf[idx]
      let inSeen = (model.seenMask >> c) & 1 == 1
      if inSeen != isRepeat { continue }
      if j == total - 1 {
        assert(c == v, "BEN_MEC: Modell-Desync im Encoder")
        break
      }
      let hit = (c == v) ? 1 : 0
      if isRepeat {
        rc.encodeBit(&model.probRepChain[model.chainContext(j, d)], hit)
      } else {
        rc.encodeBit(&model.probNewChain[model.chainContext(j, d)], hit)
      }
      if hit == 1 { break }
      j += 1
    }

    model.update(v, isRepeat: isRepeat, d: d)
  }

  private static func decode(_ model: inout MECModel, _ rc: inout RangeDecoder) -> UInt8 {
    let d = model.seenMask.nonzeroBitCount

    let isRepeat: Bool
    if d == 0 {
      isRepeat = false
    } else if d == 16 {
      isRepeat = true
    } else if d == 1 {
      isRepeat = rc.decodeBit(&model.probRun[min(model.runLength, 15)]) == 1
    } else {
      isRepeat = rc.decodeBit(&model.probRepeat[d]) == 1
    }

    let total = isRepeat ? d : 16 - d
    var v: UInt8 = 0
    var j = 0
    for idx in model.mtf.indices {
      let c = model.mtf[idx]
      let inSeen = (model.seenMask >> c) & 1 == 1
      if inSeen != isRepeat { continue }
      if j == total - 1 {
        v = c
        break
      }
      let hit: Int
      if isRepeat {
        hit = rc.decodeBit(&model.probRepChain[model.chainContext(j, d)])
      } else {
        hit = rc.decodeBit(&model.probNewChain[model.chainContext(j, d)])
      }
      if hit == 1 {
        v = c
        break
      }
      j += 1
    }

    model.update(v, isRepeat: isRepeat, d: d)
    return v
  }

  // ───────────────────────────────────────────────────────────────────────────
  // MARK: Komprimieren
  // ───────────────────────────────────────────────────────────────────────────

  @inline(__always)
  private static func nibbles(from input: Data) -> [UInt8] {
    var nibbles = [UInt8]()
    nibbles.reserveCapacity(input.count * 2)
    for byte in input {
      nibbles.append(byte >> 4)
      nibbles.append(byte & 0x0F)
    }
    return nibbles
  }

  public static func compress(_ input: Data) throws -> Data {
    // 1. Bytes → Nibbles
    var nibbles = nibbles(from: input)

    // 2. NibbleBWT: clustert gleiche Nibbles → Läufe und kurze Blöcke
    let bwtResult = NibbleBWT.transform(nibbles)
    nibbles = bwtResult.transformed

    guard UInt64(nibbles.count) <= UInt64(UInt32.max) else {
      throw BEN_MECError.fileTooLarge
    }
    let nibbleCount = UInt32(nibbles.count)
    let bwtIndex    = UInt32(bwtResult.index)

    // 3. Header
    var out = Data()
    func appendBE32(_ v: UInt32) {
      out.append(UInt8((v >> 24) & 0xFF))
      out.append(UInt8((v >> 16) & 0xFF))
      out.append(UInt8((v >>  8) & 0xFF))
      out.append(UInt8( v        & 0xFF))
    }
    appendBE32(nibbleCount)   // Offset 0: 4 B
    appendBE32(bwtIndex)      // Offset 4: 4 B

    if nibbles.isEmpty { return out }

    // 4. Ein-Pass adaptive Kodierung (vorwärts)
    var model = MECModel()
    var rc    = RangeEncoder()
    for v in nibbles {
      encode(v, &model, &rc)
    }
    rc.flush()

    out.append(contentsOf: rc.output)
    return out
  }

  // ───────────────────────────────────────────────────────────────────────────
  // MARK: Dekomprimieren
  // ───────────────────────────────────────────────────────────────────────────

  public static func decompress(_ compressed: Data) throws -> Data {
    let raw = Array(compressed)

    guard raw.count >= 8 else {
      throw BEN_MECError.invalidData("Header zu kurz (\(raw.count) < 8 Bytes)")
    }
    func readBE32(_ off: Int) -> UInt32 {
      UInt32(raw[off]) << 24 | UInt32(raw[off + 1]) << 16
        | UInt32(raw[off + 2]) << 8 | UInt32(raw[off + 3])
    }
    let nibbleCount = readBE32(0)
    let bwtIndex    = readBE32(4)

    guard nibbleCount % 2 == 0 else {
      throw BEN_MECError.invalidData("Nibble-Anzahl \(nibbleCount) ist ungerade")
    }
    if nibbleCount == 0 { return Data() }
    guard bwtIndex < nibbleCount else {
      throw BEN_MECError.invalidData("BWT-Index \(bwtIndex) ≥ Nibble-Anzahl \(nibbleCount)")
    }

    // 1. Adaptive Dekodierung — identisches Modell wie beim Kodieren
    var model = MECModel()
    var rc    = RangeDecoder(data: raw, startPos: 8)
    var nibbles = [UInt8]()
    nibbles.reserveCapacity(min(Int(nibbleCount), 1 << 22))
    for _ in 0..<Int(nibbleCount) {
      nibbles.append(decode(&model, &rc))
    }

    // 2. Inverse NibbleBWT
    let originalNibbles = NibbleBWT.inverseTransform(nibbles, index: Int(bwtIndex))

    // 3. Nibbles → Bytes
    return data(from: originalNibbles, count: nibbleCount)
  }

  private static func data(from nibbles: [UInt8], count: UInt32) -> Data {
    var result = Data(capacity: Int(count) / 2)
    for i in stride(from: 0, to: Int(count), by: 2) {
      result.append((nibbles[i] << 4) | nibbles[i + 1])
    }
    return result
  }

  // ───────────────────────────────────────────────────────────────────────────
  // MARK: Self-Test
  // ───────────────────────────────────────────────────────────────────────────

  @discardableResult
  public static func selfTest(rounds: Int = 200, bytesPerRound: Int = 512) -> Bool {
    var failures = [String]()

    func roundtrip(_ label: String, _ orig: Data) {
      do {
        let c = try compress(orig)
        let d = try decompress(c)
        if orig != d { failures.append("'\(label)': Mismatch") }
      } catch {
        failures.append("'\(label)': \(error)")
      }
    }

    let edgeCases: [(String, Data)] = [
      ("leer",           Data()),
      ("0x00",           Data([0x00])),
      ("0xFF",           Data([0xFF])),
      ("0xAB 0xCD",      Data([0xAB, 0xCD])),
      ("0x00…0xFF",      Data(0x00...0xFF)),
      ("1000× 0x00",     Data(repeating: 0x00, count: 1000)),
      ("1000× 0xFF",     Data(repeating: 0xFF, count: 1000)),
      ("1B gerade Nib.", Data([0xAA])),
      ("3B Nibble-Mix",  Data([0x12, 0x34, 0x12])),
      ("4096× 0xAB",     Data(repeating: 0xAB, count: 4096)),
      ("periodisch",     Data([UInt8]((0..<4096).map { $0 % 2 == 0 ? 0x20 : 0x02 }))),
      ("Text",           Data(String(repeating: "the quick brown fox ", count: 500).utf8)),
    ]
    for (label, orig) in edgeCases { roundtrip("Grenzfall \(label)", orig) }

    for byte in 0...255 as ClosedRange<UInt8> {
      roundtrip("Byte 0x\(String(byte, radix: 16, uppercase: true))", Data([byte]))
    }

    for r in 0..<rounds {
      let orig = Data((0..<bytesPerRound).map { _ in UInt8.random(in: 0...255) })
      roundtrip("Runde \(r)", orig)
    }

    let regressionSizes = [10_000, 100_000, 475_000, 1_000_000]
    for size in regressionSizes {
      let orig = Data((0..<size).map { _ in UInt8.random(in: 0...255) })
      roundtrip("Regression \(size)B", orig)
    }

    // Kompressions-Wirkungstest: strukturierte Daten müssen deutlich
    // schrumpfen, Zufallsdaten dürfen nur minimal wachsen.
    do {
      let text = Data(String(repeating: "Hello Nibble World! Wir komprimieren anders. ", count: 300).utf8)
      let c = try compress(text)
      if c.count * 2 > text.count {
        failures.append("Ratio: Text nicht < 50 % (\(c.count)/\(text.count))")
      }
      let rnd = Data((0..<20_000).map { _ in UInt8.random(in: 0...255) })
      let cr = try compress(rnd)
      if cr.count > rnd.count + rnd.count / 16 {
        failures.append("Ratio: Zufall wächst > 6 % (\(cr.count)/\(rnd.count))")
      }
    } catch {
      failures.append("Ratio-Test: \(error)")
    }

    if failures.isEmpty {
      print("✅ BEN_MEC Self-Test bestanden")
      print("   \(rounds) Runden × \(bytesPerRound)B + 256-Sweep + \(edgeCases.count) Grenzfälle")
      print("   + Regressionstest (10K, 100K, 475K, 1MB) + Ratio-Checks")
      print("   Bijektivität: verifiziert ✓")
      print("   Pipeline: Bytes → Nibbles → NibbleBWT → adaptiver Exclusion-Coder ✓")
    } else {
      print("❌ BEN_MEC FEHLGESCHLAGEN (\(failures.count) Fehler):")
      failures.prefix(8).forEach { print("   \($0)") }
    }
    return failures.isEmpty
  }
}
