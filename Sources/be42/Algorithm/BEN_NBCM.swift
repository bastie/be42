// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Sebastian Ritter <bastie@users.noreply.github.com>

/*
 * BEN_NBCM – nbmec-Struktur mit gemischter Dual-Rate-Statistik (Schritt 1)
 *
 * Die Grundidee bleibt unverändert die Markov-Kette / das Geburtstagsparadox
 * der Permutations-Blöcke (README) mit Exclusion-Ketten in MTF-Reihenfolge —
 * identische Kontexte wie BEN_MEC:
 *   - Repeat-Bit je Anzahl gesehener Werte d (Geburtstags-Markov-Kette)
 *   - Run-Bit je Lauflänge (d==1, Läufe nach BWT)
 *   - Exclusion-Ketten je Kettenposition × min(d,4)
 *
 * Schritt 1 (Katalog Nr. 44): jede der 183 Kontext-Wahrscheinlichkeiten ist
 * ein PAAR aus schnell (Shift 4) und langsam (Shift 7) adaptierender
 * Statistik. Ein gelernter 2er-Mixer pro Slot (logistisch, Integer-
 * Festkomma) entscheidet adaptiv, welcher Zeithorizont gerade verlässlich
 * ist. Nichts friert ein — beide Statistiken adaptieren unbegrenzt weiter.
 *
 * Schritt 4 (Katalog Nr. 35): eine APM/SSE-Stufe je Ereignisklasse
 * kalibriert die Mixer-Ausgabe anhand ihrer eigenen Fehlerhistorie nach.
 * (Schritt 2 Slot-Historie und Schritt 3 Vor-Nibble-Konditionierung wurden
 *  gemessen und verworfen — die nbmec-Struktur enthält diese Information
 *  bereits bzw. die Kontextverdünnung frisst den Gewinn.)
 *
 * Pipeline: Bytes → Nibbles → NibbleBWT → Markov-Exclusion mit
 *           Dual-Rate-Mixing → Range-Coder (12-Bit-Wahrscheinlichkeiten)
 *
 * Format: [4B nibbleCount BE] [4B bwtIndex BE] [Range-Coder-Strom]
 *
 * Bijektiv: Decoder führt das identische Modell vorwärts.
 * Rein Integer (eingebettete Sigmoid-Stützstellen) → plattformdeterministisch.
 */

import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Fehlertypen
// ─────────────────────────────────────────────────────────────────────────────

public enum BEN_NBCMError: Error, CustomStringConvertible, Sendable {
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

/// Adaptionsraten der beiden Statistiken und Mixer-Lernrate
/// (empirisch auf Projekt-Korpus: 4/7/10).
private let kFastShift = 4
private let kSlowShift = 7
private let kLearnShift = 10
/// APM/SSE-Adaptionsrate (empirisch: 5).
private let kAPMRate = 5
/// APM-Ereignisklassen: 0=Run, 1=Repeat, 2-4=RepKette, 5-7=NewKette (j-Bucket).
private let kNAPMCtx = 8

/// Slot-Layout — identische Kontexte wie BEN_MEC:
/// 0..15 Run-Bit je Lauflänge, 16..32 Repeat-Bit je d,
/// 33..107 Rep-Kette, 108..182 New-Kette (je j + 15*min(d,4)).
private let kOffRun  = 0
private let kOffRep  = 16
private let kOffRepC = 33
private let kOffNewC = 108
private let kNSlots  = 183

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Sigmoid (identische Stützstellen wie BEN_CM, rein Integer)
// ─────────────────────────────────────────────────────────────────────────────

private enum NBCMSigmoid {

  static let points: [Int] = [1, 2, 4, 6, 10, 17, 27, 45, 74, 120, 194, 311,
                              488, 747, 1102, 1546, 2048, 2550, 2994, 3349,
                              3608, 3785, 3902, 3976, 4022, 4051, 4069, 4079,
                              4086, 4090, 4092, 4094, 4095]

  private static func rawSquash(_ d: Int) -> Int {
    if d >=  2047 { return 4095 }
    if d <= -2047 { return 1 }
    let w = d & 127
    let i = (d >> 7) + 16
    return (points[i] * (128 - w) + points[i + 1] * w + 64) >> 7
  }

  static let squash: [Int16] = (-2047...2047).map { Int16(rawSquash($0)) }

  static let stretch: [Int16] = {
    var table = [Int16](repeating: 0, count: 4096)
    var j = -2047
    for p in 0..<4096 {
      while j < 2047 && rawSquash(j) < p { j += 1 }
      table[p] = Int16(j)
    }
    table[0] = -2047
    return table
  }()
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Range-Coder (12-Bit-Wahrscheinlichkeit als Parameter)
// ─────────────────────────────────────────────────────────────────────────────

private struct NBCMRangeEncoder {

  private var low:       UInt64 = 0
  private var range:     UInt32 = 0xFFFF_FFFF
  private var cache:     UInt8  = 0
  private var cacheSize: UInt64 = 1
  private(set) var output: [UInt8] = []

  /// `p0` = P(bit==0) in 1...4095.
  mutating func encode(_ p0: Int, _ bit: Int) {
    let bound = (range >> 12) &* UInt32(p0)
    if bit == 0 {
      range = bound
    } else {
      low &+= UInt64(bound)
      range &-= bound
    }
    while range < (1 << 24) {
      range <<= 8
      shiftLow()
    }
  }

  private mutating func shiftLow() {
    let low32 = UInt32(truncatingIfNeeded: low)
    if low32 < 0xFF00_0000 || low > 0xFFFF_FFFF {
      let carry = UInt8(truncatingIfNeeded: low >> 32)
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

private struct NBCMRangeDecoder {

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

  private mutating func nextByte() -> UInt8 {
    guard pos < data.count else { return 0 }
    let b = data[pos]
    pos &+= 1
    return b
  }

  mutating func decode(_ p0: Int) -> Int {
    let bound = (range >> 12) &* UInt32(p0)
    let bit: Int
    if code < bound {
      range = bound
      bit = 0
    } else {
      code &-= bound
      range &-= bound
      bit = 1
    }
    while range < (1 << 24) {
      range <<= 8
      code = (code << 8) | UInt32(nextByte())
    }
    return bit
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Modell: Markov-Exclusion mit Dual-Rate-Statistik
// ─────────────────────────────────────────────────────────────────────────────

private struct NBCMModel {

  // Dual-Rate-Statistik je Slot: P(bit==1) in 12 Bit
  var fast = [Int16](repeating: 2048, count: kNSlots)
  var slow = [Int16](repeating: 2048, count: kNSlots)
  // Mixer-Gewichte je Slot (Festkomma 16.16), Startsumme ≈ 1
  var w = [Int](repeating: 32768, count: 2 * kNSlots)

  // nbmec-Zustand (Permutations-Blockstruktur)
  var mtf: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
  var seenMask: UInt16 = 0
  var runLength: Int = 0

  // APM/SSE: Ereignisklasse × 33 Stützstellen (Schritt 4)
  var apm: [Int16] = {
    var t = [Int16](repeating: 0, count: kNAPMCtx * 33)
    for c in 0..<kNAPMCtx {
      for i in 0..<33 {
        let d = max(-2047, min(2047, (i - 16) * 128))
        t[c * 33 + i] = NBCMSigmoid.squash[d + 2047]
      }
    }
    return t
  }()

  // Zustand des aktuellen Bits (predict → update)
  private var curSlot = 0
  private var curSF = 0
  private var curSS = 0
  private var curP = 2048
  private var curAPMJ = 0

  /// Ereignisklasse eines Slots für die APM-Stufe.
  @inline(__always)
  private func apmClass(_ slot: Int) -> Int {
    if slot < kOffRep  { return 0 }
    if slot < kOffRepC { return 1 }
    if slot < kOffNewC { return 2 + min((slot - kOffRepC) % 15, 2) }
    return 5 + min((slot - kOffNewC) % 15, 2)
  }

  @inline(__always)
  mutating func predict(_ slot: Int) -> Int {
    let sf = Int(NBCMSigmoid.stretch[Int(fast[slot])])
    let ss = Int(NBCMSigmoid.stretch[Int(slow[slot])])
    curSlot = slot
    curSF = sf
    curSS = ss
    var dot = (sf &* w[2 * slot] &+ ss &* w[2 * slot + 1]) >> 16
    if dot > 2047 { dot = 2047 } else if dot < -2047 { dot = -2047 }
    var p = Int(NBCMSigmoid.squash[dot + 2047])
    if p < 1 { p = 1 } else if p > 4095 { p = 4095 }
    curP = p                                     // Mixer trainiert auf SEINE Ausgabe

    // APM/SSE: Verfeinerung anhand der Fehlerhistorie der Ereignisklasse
    let actx = apmClass(slot) * 33
    let s = Int(NBCMSigmoid.stretch[p]) + 2048
    var j = s >> 7
    let wgt = s & 127
    if j > 31 { j = 31 }
    curAPMJ = actx + j
    let pa = (Int(apm[curAPMJ]) * (128 - wgt) + Int(apm[curAPMJ + 1]) * wgt) >> 7
    var pf = (p + 3 * pa) >> 2
    if pf < 1 { pf = 1 } else if pf > 4095 { pf = 4095 }
    return pf
  }

  @inline(__always)
  mutating func update(_ bit: Int) {
    let t12 = bit << 12
    let slot = curSlot
    fast[slot] = Int16(Int(fast[slot]) + ((t12 - Int(fast[slot])) >> kFastShift))
    slow[slot] = Int16(Int(slow[slot]) + ((t12 - Int(slow[slot])) >> kSlowShift))
    let err = t12 - curP
    var wf = w[2 * slot] + ((curSF * err) >> kLearnShift)
    if wf > (1 << 20) { wf = 1 << 20 } else if wf < -(1 << 20) { wf = -(1 << 20) }
    w[2 * slot] = wf
    var ws = w[2 * slot + 1] + ((curSS * err) >> kLearnShift)
    if ws > (1 << 20) { ws = 1 << 20 } else if ws < -(1 << 20) { ws = -(1 << 20) }
    w[2 * slot + 1] = ws
    apm[curAPMJ]     = Int16(Int(apm[curAPMJ])     + ((t12 - Int(apm[curAPMJ]))     >> kAPMRate))
    apm[curAPMJ + 1] = Int16(Int(apm[curAPMJ + 1]) + ((t12 - Int(apm[curAPMJ + 1])) >> kAPMRate))
  }

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

  @inline(__always)
  mutating func pushSymbol(_ v: UInt8, isRepeat: Bool, d: Int) {
    if isRepeat {
      seenMask  = UInt16(1) << v
      runLength = (d == 1) ? runLength + 1 : 0
    } else {
      seenMask |= UInt16(1) << v
      runLength = 0
    }
    moveToFront(v)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – BEN_NBCM
// ─────────────────────────────────────────────────────────────────────────────

public enum BEN_NBCM {

  // ───────────────────────────────────────────────────────────────────────────
  // MARK: Symbol kodieren/dekodieren
  // ───────────────────────────────────────────────────────────────────────────

  private static func encode(_ v: UInt8, _ model: inout NBCMModel,
                             _ rc: inout NBCMRangeEncoder) {
    let d = model.seenMask.nonzeroBitCount
    let isRepeat = (model.seenMask >> v) & 1 == 1

    if d != 0 && d != 16 {
      let slot = d == 1 ? kOffRun + min(model.runLength, 15) : kOffRep + d
      let p = model.predict(slot)
      rc.encode(4096 - p, isRepeat ? 1 : 0)
      model.update(isRepeat ? 1 : 0)
    }

    let total = isRepeat ? d : 16 - d
    let off = isRepeat ? kOffRepC : kOffNewC
    var j = 0
    for c in model.mtf {
      let inSeen = (model.seenMask >> c) & 1 == 1
      if inSeen != isRepeat { continue }
      if j == total - 1 {
        assert(c == v, "BEN_NBCM: Modell-Desync im Encoder")
        break
      }
      let hit = (c == v) ? 1 : 0
      let p = model.predict(off + model.chainContext(j, d))
      rc.encode(4096 - p, hit)
      model.update(hit)
      if hit == 1 { break }
      j += 1
    }

    model.pushSymbol(v, isRepeat: isRepeat, d: d)
  }

  private static func decode(_ model: inout NBCMModel,
                             _ rc: inout NBCMRangeDecoder) -> UInt8 {
    let d = model.seenMask.nonzeroBitCount

    let isRepeat: Bool
    if d == 0 {
      isRepeat = false
    } else if d == 16 {
      isRepeat = true
    } else {
      let slot = d == 1 ? kOffRun + min(model.runLength, 15) : kOffRep + d
      let p = model.predict(slot)
      let bit = rc.decode(4096 - p)
      model.update(bit)
      isRepeat = bit == 1
    }

    let total = isRepeat ? d : 16 - d
    let off = isRepeat ? kOffRepC : kOffNewC
    var v: UInt8 = 0
    var j = 0
    for c in model.mtf {
      let inSeen = (model.seenMask >> c) & 1 == 1
      if inSeen != isRepeat { continue }
      if j == total - 1 {
        v = c
        break
      }
      let p = model.predict(off + model.chainContext(j, d))
      let hit = rc.decode(4096 - p)
      model.update(hit)
      if hit == 1 {
        v = c
        break
      }
      j += 1
    }

    model.pushSymbol(v, isRepeat: isRepeat, d: d)
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
    var nibbles = nibbles(from: input)
    let bwtResult = NibbleBWT.transform(nibbles)
    nibbles = bwtResult.transformed

    guard UInt64(nibbles.count) <= UInt64(UInt32.max) else {
      throw BEN_NBCMError.fileTooLarge
    }
    let nibbleCount = UInt32(nibbles.count)
    let bwtIndex    = UInt32(bwtResult.index)

    var out = Data()
    func appendBE32(_ v: UInt32) {
      out.append(UInt8((v >> 24) & 0xFF))
      out.append(UInt8((v >> 16) & 0xFF))
      out.append(UInt8((v >>  8) & 0xFF))
      out.append(UInt8( v        & 0xFF))
    }
    appendBE32(nibbleCount)
    appendBE32(bwtIndex)
    if nibbles.isEmpty { return out }

    var model = NBCMModel()
    var rc    = NBCMRangeEncoder()
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
      throw BEN_NBCMError.invalidData("Header zu kurz (\(raw.count) < 8 Bytes)")
    }
    func readBE32(_ off: Int) -> UInt32 {
      UInt32(raw[off]) << 24 | UInt32(raw[off + 1]) << 16
        | UInt32(raw[off + 2]) << 8 | UInt32(raw[off + 3])
    }
    let nibbleCount = readBE32(0)
    let bwtIndex    = readBE32(4)

    guard nibbleCount % 2 == 0 else {
      throw BEN_NBCMError.invalidData("Nibble-Anzahl \(nibbleCount) ist ungerade")
    }
    if nibbleCount == 0 { return Data() }
    guard bwtIndex < nibbleCount else {
      throw BEN_NBCMError.invalidData("BWT-Index \(bwtIndex) ≥ Nibble-Anzahl \(nibbleCount)")
    }

    var model = NBCMModel()
    var rc    = NBCMRangeDecoder(data: raw, startPos: 8)
    var nibbles = [UInt8]()
    nibbles.reserveCapacity(min(Int(nibbleCount), 1 << 22))
    for _ in 0..<Int(nibbleCount) {
      nibbles.append(decode(&model, &rc))
    }

    let originalNibbles = NibbleBWT.inverseTransform(nibbles, index: Int(bwtIndex))
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
  // MARK: Block-Zugriff für BEN_NBCMB
  // ───────────────────────────────────────────────────────────────────────────

  /// Komprimiert einen einzelnen Block (identisches Payload wie compress).
  static func compressBlock(_ input: Data) throws -> Data {
    return try compress(input)
  }

  /// Dekomprimiert einen einzelnen Block.
  static func decompressBlock(_ compressed: Data) throws -> Data {
    return try decompress(compressed)
  }

  // ───────────────────────────────────────────────────────────────────────────
  // MARK: Self-Test
  // ───────────────────────────────────────────────────────────────────────────

  @discardableResult
  public static func selfTest(rounds: Int = 100, bytesPerRound: Int = 512) -> Bool {
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

    for size in [10_000, 100_000, 1_000_000] {
      let orig = Data((0..<size).map { _ in UInt8.random(in: 0...255) })
      roundtrip("Regression \(size)B", orig)
    }

    do {
      let text = Data(String(repeating: "Hello Nibble World! Wir komprimieren anders. ",
                             count: 300).utf8)
      let c = try compress(text)
      if c.count * 2 > text.count {
        failures.append("Ratio: Text nicht < 50 % (\(c.count)/\(text.count))")
      }
    } catch {
      failures.append("Ratio-Test: \(error)")
    }

    if failures.isEmpty {
      print("✅ BEN_NBCM Self-Test bestanden")
      print("   \(rounds) Runden × \(bytesPerRound)B + 256-Sweep + \(edgeCases.count) Grenzfälle")
      print("   + Regressionstest (10K, 100K, 1MB) + Ratio-Check")
      print("   Bijektivität: verifiziert ✓")
      print("   Pipeline: Bytes → Nibbles → NibbleBWT → Markov-Exclusion + Dual-Rate-Mixing ✓")
    } else {
      print("❌ BEN_NBCM FEHLGESCHLAGEN (\(failures.count) Fehler):")
      failures.prefix(8).forEach { print("   \($0)") }
    }
    return failures.isEmpty
  }
}
