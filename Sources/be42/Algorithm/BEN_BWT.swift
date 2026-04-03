// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Sebastian Ritter <bastie@users.noreply.github.com>

/*
 * BEN_BWT – Ein Nibble-Stream rANS, bijektiv, minimaler Overhead
 *
 * RANS_L = LCM(1..16, 4096) = 184 504 320
 *   Dadurch gilt RANS_L % count == 0 für alle verwendeten Counts (1..16, ANS_M=4096).
 *   → put_uniform und put_freq sind exakt bijektiv ohne State-Drift.
 *
 * Invariante: state ∈ [RANS_L, RANS_L * RANS_B)  nach jedem put/get-Schritt.
 * Alle Werte passen in UInt64: RANS_L * RANS_B = 47 233 105 920 < 2^36.
 *
 * Format:
 *   [4B nibbleCount BE] [4B blockCount BE] [4B ransOffset BE] [4B bwtIndex BE]
 *   [32B freq 16×UInt16 BE]
 *   [1B tailCount] [ceil(tailCount/2) Bytes Nibble-Paare]
 *   [rANS-Stream ab ransOffset]
 *
 * Pipeline: Bytes → Nibbles → NibbleBWT → Segmentierung → Birthday/Markov → rANS
 *           rANS⁻¹ → NibbleBWT⁻¹ → Bytes
 *
 * Portierungs-Verifikation:
 *   Self-Test prüft Bijektivität auf Zufallsdaten + Grenzfälle + 256-Byte-Sweep.
 */

import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Fehlertypen
// ─────────────────────────────────────────────────────────────────────────────

public enum BEN_BWTError: Error, CustomStringConvertible, Sendable {
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

/// RANS_L = LCM(1..16, 4096) = 2^12 × 3^2 × 5 × 7 × 11 × 13
/// Garantie: RANS_L % c == 0 für alle c ∈ 1..16 und c == 4096.
private let RANS_L: UInt64 = 184_504_320
private let RANS_B: UInt64 = 256
private let ANS_M:  UInt64 = 4_096   // Frequenzauflösung

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – rANS Encoder
// ─────────────────────────────────────────────────────────────────────────────

/// Schreibt Symbole rückwärts in einen Byte-Puffer.
/// Decoder muss dieselben Symbole in Vorwärts-Reihenfolge lesen.
private struct RansEncoder {
  
  private(set) var state: UInt64 = RANS_L
  private(set) var output: [UInt8] = []
  
  /// Uniform ANS: val ∈ [0, count).  count == 1 → 0 Bit.
  mutating func putUniform(val: Int, count: Int) {
    guard count > 1 else { return }
    let c      = UInt64(count)
    let upper  = (RANS_L / c) * RANS_B
    var s      = state
    while s >= upper {
      output.append(UInt8(s & 0xFF))
      s >>= 8
    }
    state = s * c + UInt64(val)
  }
  
  /// Frequenz-ANS: Symbol mit Häufigkeit `freq`/ANS_M, kumuliert `cumFreq`.
  mutating func putFreq(sym: Int, freq: Int, cumFreq: Int) {
    precondition(freq > 0, "putFreq: freq muss > 0 sein")
    let f      = UInt64(freq)
    let upper  = (RANS_L / ANS_M) * RANS_B * f
    var s      = state
    while s >= upper {
      output.append(UInt8(s & 0xFF))
      s >>= 8
    }
    state = (s / f) * ANS_M + UInt64(cumFreq) + (s % f)
  }
  
  /// Flusht den finalen State als 8 Bytes (Big-Endian).
  mutating func finalize() -> [UInt8] {
    var s = state
    for _ in 0..<8 {
      output.append(UInt8(s & 0xFF))
      s >>= 8
    }
    return output.reversed()
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – rANS Decoder
// ─────────────────────────────────────────────────────────────────────────────

private struct RansDecoder {
  
  private let data: [UInt8]
  private var pos:  Int
  private(set) var state: UInt64
  
  init(data: [UInt8], startPos: Int) throws {
    guard startPos + 8 <= data.count else {
      throw BEN_BWTError.invalidData("rANS: zu wenige Bytes für State-Init")
    }
    self.data  = data
    self.pos   = startPos + 8
    var s: UInt64 = 0
    for i in 0..<8 {
      s = (s << 8) | UInt64(data[startPos + i])
    }
    self.state = s
  }
  
  private mutating func renorm() {
    while state < RANS_L && pos < data.count {
      state = (state << 8) | UInt64(data[pos])
      pos  += 1
    }
  }
  
  mutating func getUniform(count: Int) -> Int {
    guard count > 1 else { return 0 }
    let c   = UInt64(count)
    let val = Int(state % c)
    state   = state / c
    renorm()
    return val
  }
  
  mutating func getFreq(cdf: [UInt32]) -> Int {
    let slot = Int(state % ANS_M)
    var sym  = 0
    for i in 0..<16 {
      if slot < Int(cdf[i + 1]) {
        sym = i
        break
      }
    }
    let freq     = Int(cdf[sym + 1]) - Int(cdf[sym])
    let cumFreq  = Int(cdf[sym])
    state = UInt64(freq) * (state / ANS_M) + UInt64(slot - cumFreq)
    renorm()
    return sym
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Block-Datenstruktur
// ─────────────────────────────────────────────────────────────────────────────

private struct Block: Sendable {
  let distinct: [UInt8]
  let dupIdx:   Int
  let isFirst:  Bool
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Frequenztabelle
// ─────────────────────────────────────────────────────────────────────────────

private func buildFreqTable(blockLengths: [Int]) -> ([UInt16], [UInt32]) {
  var raw = [Int](repeating: 0, count: 16)
  for n in blockLengths {
    if n >= 2 && n <= 17 { raw[n - 2] += 1 }
  }
  
  let total = raw.reduce(0, +)
  var freq  = [Int](repeating: 0, count: 16)
  
  if total == 0 {
    freq[0] = Int(ANS_M)
  } else {
    for i in 0..<16 {
      if raw[i] > 0 {
        freq[i] = max(1, Int((Double(raw[i]) / Double(total) * Double(ANS_M)).rounded()))
      }
    }
    let diff  = Int(ANS_M) - freq.reduce(0, +)
    let maxI  = (0..<16).filter { freq[$0] > 0 }.max(by: { freq[$0] < freq[$1] }) ?? 0
    freq[maxI] = max(1, freq[maxI] + diff)
  }
  
  var cdf = [UInt32](repeating: 0, count: 17)
  for i in 0..<16 {
    cdf[i + 1] = cdf[i] + UInt32(freq[i])
  }
  precondition(cdf[16] == UInt32(ANS_M), "CDF-Summe ≠ ANS_M")
  
  return (freq.map { UInt16($0) }, cdf)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Segmentierung
// ─────────────────────────────────────────────────────────────────────────────

private func segmentNibbles(_ nibbles: [UInt8]) -> ([Block], [UInt8]) {
  var blocks:   [Block] = []
  var pos:      Int     = 0
  var isFirst:  Bool    = true
  var carry:    UInt8   = 0
  
  while pos < nibbles.count {
    var distinct = [UInt8]()
    var seenMask: UInt16 = 0
    
    if !isFirst {
      distinct.append(carry)
      seenMask |= (1 << carry)
    }
    
    var dupIdx:  Int? = nil
    var endPos:  Int  = pos
    
    while endPos < nibbles.count {
      let n = nibbles[endPos]
      endPos += 1
      if seenMask & (1 << n) != 0 {
        dupIdx = distinct.firstIndex(of: n)!
        break
      }
      distinct.append(n)
      seenMask |= (1 << n)
    }
    
    if let di = dupIdx {
      blocks.append(Block(distinct: distinct, dupIdx: di, isFirst: isFirst))
      carry   = distinct[di]
      isFirst = false
      pos     = endPos
    } else {
      break
    }
  }
  
  return (blocks, Array(nibbles[pos...]))
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – BEN_BWT
// ─────────────────────────────────────────────────────────────────────────────
public enum BEN_BWT {
  
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
    
    // 2. NibbleBWT-Transform: clustert gleiche Nibbles → kürzere Blöcke
    let bwtResult = NibbleBWT.transform(nibbles)
    nibbles = bwtResult.transformed
    let bwtIndex = UInt32(bwtResult.index)
    
    guard UInt64(nibbles.count) <= UInt64(UInt32.max) else {
      throw BEN_BWTError.fileTooLarge
    }
    let nibbleCount = UInt32(nibbles.count)
    
    // 3. Pass 1: Segmentierung + Häufigkeiten
    let (blocks, tail)      = segmentNibbles(nibbles)
    let blockLengths        = blocks.map { $0.distinct.count + 1 }
    let (freq, cdf)         = buildFreqTable(blockLengths: blockLengths)
    
    // 4. Header zusammenbauen
    //    Format: [nibbleCount 4B] [blockCount 4B] [ransOffset 4B] [bwtIndex 4B]
    //            [freq 16×2B] [tailCount 1B] [tail-Bytes]
    var hdr = Data()
    
    func appendBE32(_ v: UInt32) {
      hdr.append(UInt8((v >> 24) & 0xFF))
      hdr.append(UInt8((v >> 16) & 0xFF))
      hdr.append(UInt8((v >>  8) & 0xFF))
      hdr.append(UInt8( v        & 0xFF))
    }
    func appendBE16(_ v: UInt16) {
      hdr.append(UInt8((v >> 8) & 0xFF))
      hdr.append(UInt8( v       & 0xFF))
    }
    
    appendBE32(nibbleCount)              // Offset  0: 4 B
    appendBE32(UInt32(blocks.count))     // Offset  4: 4 B
    appendBE32(0)                        // Offset  8: 4 B Platzhalter ransOffset
    appendBE32(bwtIndex)                 // Offset 12: 4 B BWT-Wiederherstellungs-Index
    for f in freq { appendBE16(f) }     // Offset 16: 32 B Frequenztabelle
    hdr.append(UInt8(tail.count))        // Offset 48: 1 B
    var ti = 0
    while ti < tail.count {
      let hi = tail[ti]
      let lo = (ti + 1 < tail.count) ? tail[ti + 1] : 0
      hdr.append((hi << 4) | lo)
      ti += 2
    }
    
    // ransOffset eintragen (Offset 8..11 im Header)
    let ransOffset = UInt32(hdr.count)
    hdr[8]  = UInt8((ransOffset >> 24) & 0xFF)
    hdr[9]  = UInt8((ransOffset >> 16) & 0xFF)
    hdr[10] = UInt8((ransOffset >>  8) & 0xFF)
    hdr[11] = UInt8( ransOffset        & 0xFF)
    
    // 5. Pass 2: rANS rückwärts kodieren
    var rans = RansEncoder()
    
    for block in blocks.reversed() {
      let dc = block.distinct.count
      
      // a) dupIdx
      rans.putUniform(val: block.dupIdx, count: dc)
      
      // b) Choices für distinct[1..dc-1] rückwärts
      var available: [UInt8] = [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]
      available.remove(at: available.firstIndex(of: block.distinct[0])!)
      var avSnap = available
      
      var choices = [(idx: Int, count: Int)]()
      for i in 1..<dc {
        let idx = avSnap.firstIndex(of: block.distinct[i])!
        choices.append((idx: idx, count: avSnap.count))
        avSnap.remove(at: idx)
      }
      for c in choices.reversed() {
        rans.putUniform(val: c.idx, count: c.count)
      }
      
      // c) distinct[0] nur beim ersten Block
      if block.isFirst {
        rans.putUniform(val: Int(block.distinct[0]), count: 16)
      }
      
      // d) Blocklänge
      let sym = dc - 1
      rans.putFreq(sym: sym, freq: Int(freq[sym]), cumFreq: Int(cdf[sym]))
    }
    
    let ransBytes = rans.finalize()
    
    var out = hdr
    out.append(contentsOf: ransBytes)
    return out
  }
  
  // ───────────────────────────────────────────────────────────────────────────
  // MARK: Dekomprimieren
  // ───────────────────────────────────────────────────────────────────────────
  
  public static func decompress(_ compressed: Data) throws -> Data {
    
    let raw = Array(compressed)
    var off = 0
    
    func readBE32() throws -> UInt32 {
      guard off + 4 <= raw.count else {
        throw BEN_BWTError.invalidData("Header zu kurz (UInt32 bei Offset \(off))")
      }
      let v = UInt32(raw[off]) << 24 | UInt32(raw[off+1]) << 16
      | UInt32(raw[off+2]) <<  8 | UInt32(raw[off+3])
      off += 4
      return v
    }
    func readBE16() throws -> UInt16 {
      guard off + 2 <= raw.count else {
        throw BEN_BWTError.invalidData("Header zu kurz (UInt16 bei Offset \(off))")
      }
      let v = UInt16(raw[off]) << 8 | UInt16(raw[off+1])
      off += 2
      return v
    }
    func readByte() throws -> UInt8 {
      guard off < raw.count else {
        throw BEN_BWTError.invalidData("Header zu kurz (Byte bei Offset \(off))")
      }
      let v = raw[off]; off += 1; return v
    }
    
    // Header lesen
    let nibbleCount = try readBE32()   // Offset  0
    let blockCount  = try readBE32()   // Offset  4
    let ransOffset  = try readBE32()   // Offset  8
    let bwtIndex    = try readBE32()   // Offset 12  ← NEU
    
    var freq = [UInt16](repeating: 0, count: 16)
    for i in 0..<16 { freq[i] = try readBE16() }
    
    var cdf = [UInt32](repeating: 0, count: 17)
    for i in 0..<16 { cdf[i + 1] = cdf[i] + UInt32(freq[i]) }
    guard cdf[16] == UInt32(ANS_M) else {
      throw BEN_BWTError.invalidData("Frequenztabelle inkonsistent (Summe ≠ \(ANS_M))")
    }
    
    let tailCount = Int(try readByte())
    var tailNibbles = [UInt8]()
    let tailBytes = (tailCount + 1) / 2
    for _ in 0..<tailBytes {
      let b = try readByte()
      tailNibbles.append(b >> 4)
      tailNibbles.append(b & 0x0F)
    }
    tailNibbles = Array(tailNibbles.prefix(tailCount))
    
    guard Int(ransOffset) <= raw.count else {
      throw BEN_BWTError.invalidData("ransOffset \(ransOffset) überschreitet Dateilänge")
    }
    var rans = try RansDecoder(data: raw, startPos: Int(ransOffset))
    
    var nibbles  = [UInt8]()
    nibbles.reserveCapacity(Int(nibbleCount))
    var isFirst  = true
    var carry: UInt8 = 0
    
    for _ in 0..<Int(blockCount) {
      let sym = rans.getFreq(cdf: cdf)
      let n   = sym + 2
      let dc  = n - 1
      
      var available: [UInt8] = [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]
      var distinct  = [UInt8](repeating: 0, count: dc)
      
      if isFirst {
        let idx = rans.getUniform(count: 16)
        guard idx < available.count else {
          throw BEN_BWTError.invalidData("Ungültiger distinct[0]-Index \(idx)")
        }
        distinct[0] = available[idx]
        available.remove(at: idx)
      } else {
        distinct[0] = carry
        available.remove(at: available.firstIndex(of: carry)!)
      }
      
      var avSnap = available
      for i in 1..<dc {
        let idx = rans.getUniform(count: avSnap.count)
        guard idx < avSnap.count else {
          throw BEN_BWTError.invalidData("Ungültiger distinct[\(i)]-Index \(idx)")
        }
        distinct[i] = avSnap[idx]
        avSnap.remove(at: idx)
      }
      
      let dupIdx = rans.getUniform(count: dc)
      guard dupIdx < dc else {
        throw BEN_BWTError.invalidData("Ungültiger dupIdx \(dupIdx)")
      }
      
      let start = isFirst ? 0 : 1
      for i in start..<dc { nibbles.append(distinct[i]) }
      nibbles.append(distinct[dupIdx])
      
      carry   = distinct[dupIdx]
      isFirst = false
    }
    
    nibbles.append(contentsOf: tailNibbles)
    
    guard nibbles.count >= Int(nibbleCount) else {
      throw BEN_BWTError.invalidData(
        "Zu wenige Nibbles dekodiert: \(nibbles.count) < \(nibbleCount)")
    }
    
    // NibbleBWT inverse Transform: BWT-Output → originaler Nibble-Stream
    let originalNibbles = NibbleBWT.inverseTransform(nibbles, index: Int(bwtIndex))
    
    // Nibbles → Bytes
    let result = data(from: originalNibbles, count: nibbleCount)
    
    return result
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
    
    let edgeCases: [(String, Data)] = [
      ("leer",           Data()),
      ("0x00",           Data([0x00])),
      ("0xFF",           Data([0xFF])),
      ("0xAB 0xCD",      Data([0xAB, 0xCD])),
      ("0x00…0xFF",      Data(0x00...0xFF)),
      ("1000× 0x00",     Data(repeating: 0x00, count: 1000)),
      ("1000× 0xFF",     Data(repeating: 0xFF, count: 1000)),
      ("1024B Zufall",   Data((0..<1024).map { _ in UInt8.random(in: 0...255) })),
      ("1B gerade Nib.", Data([0xAA])),
      ("3B Nibble-Mix",  Data([0x12, 0x34, 0x12])),
    ]
    for (label, orig) in edgeCases {
      do {
        let c = try compress(orig)
        let d = try decompress(c)
        if orig != d { failures.append("Grenzfall '\(label)': Mismatch") }
      } catch {
        failures.append("Grenzfall '\(label)': \(error)")
      }
    }
    
    for r in 0..<rounds {
      let orig = Data((0..<bytesPerRound).map { _ in UInt8.random(in: 0...255) })
      do {
        let c = try compress(orig)
        let d = try decompress(c)
        if orig != d { failures.append("Runde \(r): Mismatch") }
      } catch {
        failures.append("Runde \(r): \(error)")
      }
    }
    
    for byte in 0...255 as ClosedRange<UInt8> {
      let orig = Data([byte])
      do {
        let c = try compress(orig)
        let d = try decompress(c)
        if orig != d { failures.append("Byte 0x\(String(byte, radix: 16, uppercase: true))") }
      } catch {
        failures.append("Byte 0x\(String(byte, radix: 16, uppercase: true)): \(error)")
      }
    }
    
    let regressionSizes = [10_000, 100_000, 475_000, 1_000_000]
    for size in regressionSizes {
      let orig = Data((0..<size).map { _ in UInt8.random(in: 0...255) })
      do {
        let c = try compress(orig)
        let d = try decompress(c)
        if orig != d { failures.append("Regression \(size)B: Mismatch") }
      } catch {
        failures.append("Regression \(size)B: \(error)")
      }
    }
    
    if failures.isEmpty {
      print("✅ BEN_BWT Self-Test bestanden")
      print("   \(rounds) Runden × \(bytesPerRound)B + 256-Sweep + \(edgeCases.count) Grenzfälle")
      print("   + Regressionstest (10K, 100K, 475K, 1MB)")
      print("   Bijektivität: verifiziert ✓")
      print("   Pipeline: Bytes → Nibbles → NibbleBWT → rANS ✓")
    } else {
      print("❌ BEN_BWT FEHLGESCHLAGEN (\(failures.count) Fehler):")
      failures.prefix(8).forEach { print("   \($0)") }
    }
    return failures.isEmpty
  }
}
