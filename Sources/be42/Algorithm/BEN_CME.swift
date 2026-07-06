// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Sebastian Ritter <bastie@users.noreply.github.com>

/*
 * BEN_CME – ncmm erweitert (nibble.context.mixing.match.extended, 0x07)
 * Katalog Nr. 59, Schritt 13 — Python-Referenz: ben_cm4_proto.py
 *
 * GRUNDPRINZIP UNANGETASTET: Permutation / Markov-Kette / Geburtstags-
 * paradoxon bleiben das Fundament — BEN_CME ergänzt die geparkte ncmm-Linie
 * (BEN_CM, 0x03) ausschließlich um zusätzliche implizite Informations-
 * quellen, die dort kausal verfügbar sind:
 *
 *   1. ALIGNMENT (Nr. 12/27): Byte-Position mod 8 als eigenes Kontext-
 *      modell. In der BWT-freien ncmm-Linie ist die Original-Position
 *      kausal verfügbar (Encoder und Decoder zählen identisch mit) — der
 *      Architektur-Konflikt der nbcm-Linie existiert hier nicht.
 *      Gemessen (Python, Schritt 13a): Zielfall 4-Byte-Stride-Binärdaten
 *      −8,32 %, feste Record-Breiten −0,19 %, Text +0,2…+0,5 %.
 *
 *   2. TIEFE KONTEXTE (Nr. 2): Order-8 und Order-12 (Hash + Prüfsumme).
 *      Der zpaq-Kapazitätsmechanismus (Nr.-59-Diagnose): Gewinn wächst
 *      mit der Dateigröße — enwik8 40K −0,22 %, 120K −0,51 % (Python);
 *      auf MB-Skala mehr zu erwarten.
 *
 *   Nr. 34 (Match-Exclusion) wurde gemessen und verworfen (überall
 *   neutral) — bewusst NICHT portiert.
 *
 * BIJEKTIVITÄT: beide Erweiterungen nutzen ausschließlich bereits
 * dekodierte Symbole bzw. daraus abgeleiteten Zustand (Bytezähler,
 * Nibble-Historie) — der Decoder spielt exakt dasselbe Modell vorwärts.
 * Payload-Header wie BEN_CM: 4 Byte Byte-Anzahl.
 *
 * SAFE/UNSAFE: das komplette Modell existiert doppelt — CMEModel
 * (Swift-Arrays, Bounds-Checks) und CMEModelU (rohe Pointer). Auswahl
 * über denselben --unsafe-Schalter wie beim Coder; bitidentische Ausgabe
 * wird durch Tests erzwungen.
 *
 * --gpu ist für diese Linie wirkungslos: ncmm hat keine BWT und damit
 * keine Suffix-Sortierung — es gibt nichts zu beschleunigen.
 *
 * Formatkompatibilität: BEN_CM (0x03) bleibt unverändert dekodierbar;
 * BEN_CME schreibt eigene Ströme unter Algorithmus-Byte 0x07.
 */

import Foundation

public enum BEN_CMEError: Error, CustomStringConvertible, Sendable {
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
// MARK: – Konstanten (Basis identisch zu BEN_CM, plus Order-8/12)
// ─────────────────────────────────────────────────────────────────────────────

private let kO3Bits = 24
private let kO4Bits = 25
private let kO6Bits = 25
private let kWDBits = 24
private let kSPBits = 22
private let kMMBits = 24
/// Neu (Nr. 2): Order-8 und Order-12 — Kapazität Richtung zpaq-Diagnose.
private let kO8Bits = 24
private let kO12Bits = 24
private let kLearnShift = 9
private let kMatchMin = 5
private let kAPMRate = 6
private let kRate: [Int] = [2, 2, 3, 3, 4, 4, 4, 5, 5, 5, 6, 6, 6, 6, 7, 7]
/// 12 Modelle: o0,o1,o2,o3,o4,o6,Wort,Sparse,Match + Alignment + Order-8 + Order-12
private let kNModels = 12

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Sigmoid (identisch zur validierten Referenz)
// ─────────────────────────────────────────────────────────────────────────────

private enum Sigmoid {

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

@inline(__always) private func squash(_ d: Int) -> Int {
  return Int(Sigmoid.squash[d + 2047])
}
@inline(__always) private func stretch(_ p: Int) -> Int {
  return Int(Sigmoid.stretch[p])
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Range-Coder (identisch zu BEN_CM)
// ─────────────────────────────────────────────────────────────────────────────

private struct CMERangeEncoder {

  private var low:       UInt64 = 0
  private var range:     UInt32 = 0xFFFF_FFFF
  private var cache:     UInt8  = 0
  private var cacheSize: UInt64 = 1
  private(set) var output: [UInt8] = []

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

private struct CMERangeDecoder {

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
// MARK: – Modell (safe: Swift-Arrays mit Bounds-Checks)
// ─────────────────────────────────────────────────────────────────────────────

/// Gemeinsamer Modellzustand von Encoder und Decoder (Referenztyp:
/// große Tabellen ohne COW-Kopien). Beide Seiten führen exakt dieselben
/// Updates aus → Bijektivität.
private final class CMEModel {

  // Basis (identisch zu BEN_CM)
  var o0p = [Int16](repeating: 2048, count: 2 * 15)
  var o0c = [UInt8](repeating: 0, count: 2 * 15)
  var o1p = [Int16](repeating: 2048, count: 512 * 15)
  var o1c = [UInt8](repeating: 0, count: 512 * 15)
  var o2p = [Int16](repeating: 2048, count: 131_072 * 15)
  var o2c = [UInt8](repeating: 0, count: 131_072 * 15)
  var o3p = [Int16](repeating: 2048, count: 1 << kO3Bits)
  var o3c = [UInt8](repeating: 0, count: 1 << kO3Bits)
  var o3k = [UInt8](repeating: 0, count: 1 << kO3Bits)
  var o4p = [Int16](repeating: 2048, count: 1 << kO4Bits)
  var o4c = [UInt8](repeating: 0, count: 1 << kO4Bits)
  var o4k = [UInt8](repeating: 0, count: 1 << kO4Bits)
  var o6p = [Int16](repeating: 2048, count: 1 << kO6Bits)
  var o6c = [UInt8](repeating: 0, count: 1 << kO6Bits)
  var o6k = [UInt8](repeating: 0, count: 1 << kO6Bits)
  var wdp = [Int16](repeating: 2048, count: 1 << kWDBits)
  var wdc = [UInt8](repeating: 0, count: 1 << kWDBits)
  var wdk = [UInt8](repeating: 0, count: 1 << kWDBits)
  var spp = [Int16](repeating: 2048, count: 1 << kSPBits)
  var spc = [UInt8](repeating: 0, count: 1 << kSPBits)
  var spk = [UInt8](repeating: 0, count: 1 << kSPBits)

  // Neu: Alignment (Nr. 12/27) — Byte-Position mod 8, direkt indiziert
  var alp = [Int16](repeating: 2048, count: 8 * 2 * 15)
  var alc = [UInt8](repeating: 0, count: 8 * 2 * 15)

  // Neu: Order-8 / Order-12 (Nr. 2) — Hash + Prüfsumme
  var o8p = [Int16](repeating: 2048, count: 1 << kO8Bits)
  var o8c = [UInt8](repeating: 0, count: 1 << kO8Bits)
  var o8k = [UInt8](repeating: 0, count: 1 << kO8Bits)
  var o12p = [Int16](repeating: 2048, count: 1 << kO12Bits)
  var o12c = [UInt8](repeating: 0, count: 1 << kO12Bits)
  var o12k = [UInt8](repeating: 0, count: 1 << kO12Bits)

  // Match-Modell
  var mmtab = [UInt32](repeating: 0, count: 1 << kMMBits)
  var buf = [UInt8]()
  var matchPtr = 0
  var matchLen = 0
  var mmp = [Int16](repeating: 2048, count: 16)
  var mmc = [UInt8](repeating: 0, count: 16)

  // Mixer: 64 Gewichtssätze × kNModels
  var wx = [Int](repeating: 65536 / kNModels, count: 64 * kNModels)

  var apm: [Int16] = CMEModel.apmInit(rows: 256)
  var apm2: [Int16] = CMEModel.apmInit(rows: 32)

  static func apmInit(rows: Int) -> [Int16] {
    var t = [Int16](repeating: 0, count: rows * 33)
    for c in 0..<rows {
      for i in 0..<33 {
        let d = max(-2047, min(2047, (i - 16) * 128))
        t[c * 33 + i] = Sigmoid.squash[d + 2047]
      }
    }
    return t
  }

  // Verlauf: hist = letzte 16 Nibbles; histHi erweitert auf 24 Nibbles
  // (96 Bit) für den Order-12-Kontext — histHi hält die Bits 64...95.
  var hist: UInt64 = 0
  var histHi: UInt64 = 0
  var isHigh = 1
  var pendingHigh = 0
  var wordHash: UInt32 = 0

  // Zustand des aktuellen Bits (predict → update)
  var i0 = 0, i1 = 0, i2 = 0, h3 = 0, h4 = 0, h6 = 0, hw = 0, hs = 0
  var ia = 0, h8 = 0, h12 = 0
  var st = [Int](repeating: 0, count: kNModels)
  var mmBucket = -1
  var mmExpectedBit = 0
  var mctx = 0
  var pMix = 2048
  var apmJ = 0
  var apm2J = 0

  func predict(node: Int, depth: Int) -> Int {
    let hi = isHigh
    i0 = hi * 15 + node - 1
    i1 = (Int(hist & 0xFF) << 1 | hi) * 15 + node - 1
    i2 = (Int(hist & 0xFFFF) << 1 | hi) * 15 + node - 1
    let f3 = UInt32(truncatingIfNeeded: hist & 0xFF_FFFF) &* 0x9E37_79B1
             &+ UInt32(node) &* 0x85EB_CA77
             &+ UInt32(hi) &* 0xC2B2_AE3D
    let f4 = UInt32(truncatingIfNeeded: hist) &* 0x27D4_EB2F
             &+ UInt32(node) &* 0x1656_67B1
             &+ UInt32(hi) &* 0x9E37_79B1
    let f6 = (hist & 0xFFFF_FFFF_FFFF) &* 0x9E37_79B9_7F4A_7C15
             &+ UInt64(node) &* 0x1656_67B1
             &+ UInt64(hi) &* 0x27D4_EB2F
    let fw = wordHash &* 0xB529_7A4D
             &+ UInt32(node) &* 0x68E3_1DA4
             &+ UInt32(hi) &* 0x1B56_C4E9
    let n = buf.count
    let s2: UInt32 = n >= 2 ? UInt32(buf[n - 2]) : 0
    let s4: UInt32 = n >= 4 ? UInt32(buf[n - 4]) : 0
    let fs = (s2 << 8 | s4) &* 0x9E37_79B1
             &+ UInt32(node) &* 0x27D4_EB2F
             &+ UInt32(hi) &* 0x85EB_CA77
    // Neu: Order-8 (volle 64-Bit-Nibble-Historie) und Order-12 (96 Bit)
    let f8 = hist &* 0xFF51_AFD7_ED55_8CCD
             &+ UInt64(node) &* 0xC4CE_B9FE_1A85_EC53
             &+ UInt64(hi) &* 0x9E37_79B9
    let f12 = hist &* 0x2545_F491_4F6C_DD1D
              &+ histHi &* 0x9E37_79B9_7F4A_7C15
              &+ UInt64(node) &* 0x85EB_CA77
              &+ UInt64(hi) &* 0x27D4_EB2F

    h3 = Int(f3 >> (32 - kO3Bits))
    h4 = Int(f4 >> (32 - kO4Bits))
    h6 = Int(f6 >> (64 - kO6Bits))
    hw = Int(fw >> (32 - kWDBits))
    hs = Int(fs >> (32 - kSPBits))
    h8 = Int(f8 >> (64 - kO8Bits))
    h12 = Int(f12 >> (64 - kO12Bits))
    ia = (((n & 7) << 1) | hi) * 15 + node - 1

    let k3 = UInt8(truncatingIfNeeded: f3)
    if o3k[h3] != k3 { o3p[h3] = 2048; o3c[h3] = 0; o3k[h3] = k3 }
    let k4 = UInt8(truncatingIfNeeded: f4)
    if o4k[h4] != k4 { o4p[h4] = 2048; o4c[h4] = 0; o4k[h4] = k4 }
    let k6 = UInt8(truncatingIfNeeded: f6)
    if o6k[h6] != k6 { o6p[h6] = 2048; o6c[h6] = 0; o6k[h6] = k6 }
    let kw = UInt8(truncatingIfNeeded: fw)
    if wdk[hw] != kw { wdp[hw] = 2048; wdc[hw] = 0; wdk[hw] = kw }
    let ks = UInt8(truncatingIfNeeded: fs)
    if spk[hs] != ks { spp[hs] = 2048; spc[hs] = 0; spk[hs] = ks }
    let k8 = UInt8(truncatingIfNeeded: f8)
    if o8k[h8] != k8 { o8p[h8] = 2048; o8c[h8] = 0; o8k[h8] = k8 }
    let k12 = UInt8(truncatingIfNeeded: f12)
    if o12k[h12] != k12 { o12p[h12] = 2048; o12c[h12] = 0; o12k[h12] = k12 }

    st[0] = stretch(Int(o0p[i0]))
    st[1] = stretch(Int(o1p[i1]))
    st[2] = stretch(Int(o2p[i2]))
    st[3] = stretch(Int(o3p[h3]))
    st[4] = stretch(Int(o4p[h4]))
    st[5] = stretch(Int(o6p[h6]))
    st[6] = stretch(Int(wdp[hw]))
    st[7] = stretch(Int(spp[hs]))

    mmBucket = -1
    mmExpectedBit = 0
    if matchLen > 0 && matchPtr < n {
      let e = Int(buf[matchPtr])
      let en = hi == 1 ? (e >> 4) : (e & 0xF)
      if node == (1 << depth) | (en >> (4 - depth)) {
        mmBucket = min(matchLen, 15)
        mmExpectedBit = (en >> (3 - depth)) & 1
      }
    }
    if mmBucket >= 0 {
      let s = stretch(Int(mmp[mmBucket]))
      st[8] = mmExpectedBit == 1 ? s : -s
    } else {
      st[8] = 0
    }

    // Neu: Alignment + Order-8 + Order-12 (Reihenfolge wie Python-Referenz)
    st[9]  = stretch(Int(alp[ia]))
    st[10] = stretch(Int(o8p[h8]))
    st[11] = stretch(Int(o12p[h12]))

    mctx = ((Int(hist & 0xF) << 2) | (hi << 1) | (matchLen > 0 ? 1 : 0))
           * kNModels
    var dot = 0
    for i in 0..<kNModels {
      dot &+= st[i] &* wx[mctx + i]
    }
    dot >>= 16
    if dot > 2047 { dot = 2047 } else if dot < -2047 { dot = -2047 }
    pMix = squash(dot)

    let actx = Int(hist & 0xFF) * 33
    let s = stretch(pMix) + 2048
    var j = s >> 7
    let w = s & 127
    if j > 31 { j = 31 }
    apmJ = actx + j
    let pa = (Int(apm[apmJ]) * (128 - w) + Int(apm[apmJ + 1]) * w) >> 7
    var p1 = (pMix + 3 * pa) >> 2
    if p1 < 1 { p1 = 1 } else if p1 > 4095 { p1 = 4095 }

    let a2ctx = ((min(matchLen, 15) << 1) | hi) * 33
    let sq2 = stretch(p1) + 2048
    var j2 = sq2 >> 7
    let w2 = sq2 & 127
    if j2 > 31 { j2 = 31 }
    apm2J = a2ctx + j2
    let pb = (Int(apm2[apm2J]) * (128 - w2) + Int(apm2[apm2J + 1]) * w2) >> 7
    var pFinal = (p1 + 3 * pb) >> 2
    if pFinal < 1 { pFinal = 1 } else if pFinal > 4095 { pFinal = 4095 }
    return pFinal
  }

  func update(bit: Int) {
    let t12 = bit << 12

    var c = Int(o0c[i0])
    o0p[i0] = Int16(Int(o0p[i0]) + ((t12 - Int(o0p[i0])) >> kRate[c]))
    if c < 15 { o0c[i0] = UInt8(c + 1) }
    c = Int(o1c[i1])
    o1p[i1] = Int16(Int(o1p[i1]) + ((t12 - Int(o1p[i1])) >> kRate[c]))
    if c < 15 { o1c[i1] = UInt8(c + 1) }
    c = Int(o2c[i2])
    o2p[i2] = Int16(Int(o2p[i2]) + ((t12 - Int(o2p[i2])) >> kRate[c]))
    if c < 15 { o2c[i2] = UInt8(c + 1) }
    c = Int(o3c[h3])
    o3p[h3] = Int16(Int(o3p[h3]) + ((t12 - Int(o3p[h3])) >> kRate[c]))
    if c < 15 { o3c[h3] = UInt8(c + 1) }
    c = Int(o4c[h4])
    o4p[h4] = Int16(Int(o4p[h4]) + ((t12 - Int(o4p[h4])) >> kRate[c]))
    if c < 15 { o4c[h4] = UInt8(c + 1) }
    c = Int(o6c[h6])
    o6p[h6] = Int16(Int(o6p[h6]) + ((t12 - Int(o6p[h6])) >> kRate[c]))
    if c < 15 { o6c[h6] = UInt8(c + 1) }
    c = Int(wdc[hw])
    wdp[hw] = Int16(Int(wdp[hw]) + ((t12 - Int(wdp[hw])) >> kRate[c]))
    if c < 15 { wdc[hw] = UInt8(c + 1) }
    c = Int(spc[hs])
    spp[hs] = Int16(Int(spp[hs]) + ((t12 - Int(spp[hs])) >> kRate[c]))
    if c < 15 { spc[hs] = UInt8(c + 1) }
    // Neu: Alignment + Order-8 + Order-12
    c = Int(alc[ia])
    alp[ia] = Int16(Int(alp[ia]) + ((t12 - Int(alp[ia])) >> kRate[c]))
    if c < 15 { alc[ia] = UInt8(c + 1) }
    c = Int(o8c[h8])
    o8p[h8] = Int16(Int(o8p[h8]) + ((t12 - Int(o8p[h8])) >> kRate[c]))
    if c < 15 { o8c[h8] = UInt8(c + 1) }
    c = Int(o12c[h12])
    o12p[h12] = Int16(Int(o12p[h12]) + ((t12 - Int(o12p[h12])) >> kRate[c]))
    if c < 15 { o12c[h12] = UInt8(c + 1) }

    if mmBucket >= 0 {
      let hitv = bit == mmExpectedBit ? 4096 : 0
      let cb = Int(mmc[mmBucket])
      mmp[mmBucket] = Int16(Int(mmp[mmBucket]) + ((hitv - Int(mmp[mmBucket])) >> kRate[cb]))
      if cb < 15 { mmc[mmBucket] = UInt8(cb + 1) }
      if bit != mmExpectedBit { matchLen = 0 }
    }

    let err = t12 - pMix
    for i in 0..<kNModels {
      var w = wx[mctx + i] + ((st[i] * err) >> kLearnShift)
      if w > (1 << 20) { w = 1 << 20 } else if w < -(1 << 20) { w = -(1 << 20) }
      wx[mctx + i] = w
    }

    apm[apmJ]     = Int16(Int(apm[apmJ])     + ((t12 - Int(apm[apmJ]))     >> kAPMRate))
    apm[apmJ + 1] = Int16(Int(apm[apmJ + 1]) + ((t12 - Int(apm[apmJ + 1])) >> kAPMRate))
    apm2[apm2J]     = Int16(Int(apm2[apm2J])     + ((t12 - Int(apm2[apm2J]))     >> kAPMRate))
    apm2[apm2J + 1] = Int16(Int(apm2[apm2J + 1]) + ((t12 - Int(apm2[apm2J + 1])) >> kAPMRate))
  }

  func pushNibble(_ v: Int) {
    // 96-Bit-Historie: histHi übernimmt die herausgeschobenen Bits von hist
    histHi = ((histHi << 4) | (hist >> 60)) & 0xFFFF_FFFF
    hist = (hist << 4) | UInt64(v)
    if isHigh == 1 {
      pendingHigh = v
      isHigh = 0
    } else {
      let byte = UInt8((pendingHigh << 4) | v)
      buf.append(byte)
      isHigh = 1
      if (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) {
        wordHash = wordHash &* 271 &+ UInt32(byte | 0x20)
      } else {
        wordHash = 0
      }
      matchUpdate()
    }
  }

  private func matchUpdate() {
    let n = buf.count
    if matchLen > 0 {
      if buf[n - 1] == buf[matchPtr] {
        matchPtr += 1
        matchLen += 1
      } else {
        matchLen = 0
      }
    }
    if n >= kMatchMin {
      var h: UInt32 = 0
      for k in 0..<kMatchMin {
        h = h &* 0x9E37_79B1 &+ UInt32(buf[n - 1 - k]) &+ 1
      }
      let idx = Int(h >> (32 - kMMBits))
      if matchLen == 0 {
        let cand = Int(mmtab[idx])
        if cand > 0 && cand < n {
          matchPtr = cand
          matchLen = 1
        }
      }
      mmtab[idx] = UInt32(n)
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Modell (unsafe: rohe Pointer, keine Bounds-Checks)
// ─────────────────────────────────────────────────────────────────────────────

private func allocI16(_ count: Int, _ value: Int16) -> UnsafeMutablePointer<Int16> {
  let p = UnsafeMutablePointer<Int16>.allocate(capacity: count)
  p.initialize(repeating: value, count: count)
  return p
}
private func allocU8(_ count: Int) -> UnsafeMutablePointer<UInt8> {
  let p = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
  p.initialize(repeating: 0, count: count)
  return p
}
private func allocU32(_ count: Int) -> UnsafeMutablePointer<UInt32> {
  let p = UnsafeMutablePointer<UInt32>.allocate(capacity: count)
  p.initialize(repeating: 0, count: count)
  return p
}
private func allocInt(_ count: Int, _ value: Int) -> UnsafeMutablePointer<Int> {
  let p = UnsafeMutablePointer<Int>.allocate(capacity: count)
  p.initialize(repeating: value, count: count)
  return p
}

/// Identische Logik wie CMEModel, aber alle Tabellen als rohe Pointer —
/// keine Bounds-Checks, keine COW-Prüfungen. Bitidentische Ausgabe wird
/// durch den Self-Test und die Unit-Tests erzwungen.
private final class CMEModelU {

  let o0p: UnsafeMutablePointer<Int16>; let o0c: UnsafeMutablePointer<UInt8>
  let o1p: UnsafeMutablePointer<Int16>; let o1c: UnsafeMutablePointer<UInt8>
  let o2p: UnsafeMutablePointer<Int16>; let o2c: UnsafeMutablePointer<UInt8>
  let o3p: UnsafeMutablePointer<Int16>; let o3c: UnsafeMutablePointer<UInt8>; let o3k: UnsafeMutablePointer<UInt8>
  let o4p: UnsafeMutablePointer<Int16>; let o4c: UnsafeMutablePointer<UInt8>; let o4k: UnsafeMutablePointer<UInt8>
  let o6p: UnsafeMutablePointer<Int16>; let o6c: UnsafeMutablePointer<UInt8>; let o6k: UnsafeMutablePointer<UInt8>
  let wdp: UnsafeMutablePointer<Int16>; let wdc: UnsafeMutablePointer<UInt8>; let wdk: UnsafeMutablePointer<UInt8>
  let spp: UnsafeMutablePointer<Int16>; let spc: UnsafeMutablePointer<UInt8>; let spk: UnsafeMutablePointer<UInt8>
  let alp: UnsafeMutablePointer<Int16>; let alc: UnsafeMutablePointer<UInt8>
  let o8p: UnsafeMutablePointer<Int16>; let o8c: UnsafeMutablePointer<UInt8>; let o8k: UnsafeMutablePointer<UInt8>
  let o12p: UnsafeMutablePointer<Int16>; let o12c: UnsafeMutablePointer<UInt8>; let o12k: UnsafeMutablePointer<UInt8>
  let mmtab: UnsafeMutablePointer<UInt32>
  let mmp: UnsafeMutablePointer<Int16>; let mmc: UnsafeMutablePointer<UInt8>
  let wx: UnsafeMutablePointer<Int>
  let apm: UnsafeMutablePointer<Int16>
  let apm2: UnsafeMutablePointer<Int16>
  let st: UnsafeMutablePointer<Int>

  let buf: UnsafeMutablePointer<UInt8>
  var bufCount = 0
  let bufCapacity: Int
  var matchPtr = 0
  var matchLen = 0

  var hist: UInt64 = 0
  var histHi: UInt64 = 0
  var isHigh = 1
  var pendingHigh = 0
  var wordHash: UInt32 = 0

  var i0 = 0, i1 = 0, i2 = 0, h3 = 0, h4 = 0, h6 = 0, hw = 0, hs = 0
  var ia = 0, h8 = 0, h12 = 0
  var mmBucket = -1
  var mmExpectedBit = 0
  var mctx = 0
  var pMix = 2048

  var apmJ = 0
  var apm2J = 0

  init(capacity: Int) {
    o0p = allocI16(2 * 15, 2048);            o0c = allocU8(2 * 15)
    o1p = allocI16(512 * 15, 2048);          o1c = allocU8(512 * 15)
    o2p = allocI16(131_072 * 15, 2048);      o2c = allocU8(131_072 * 15)
    o3p = allocI16(1 << kO3Bits, 2048);      o3c = allocU8(1 << kO3Bits);  o3k = allocU8(1 << kO3Bits)
    o4p = allocI16(1 << kO4Bits, 2048);      o4c = allocU8(1 << kO4Bits);  o4k = allocU8(1 << kO4Bits)
    o6p = allocI16(1 << kO6Bits, 2048);      o6c = allocU8(1 << kO6Bits);  o6k = allocU8(1 << kO6Bits)
    wdp = allocI16(1 << kWDBits, 2048);      wdc = allocU8(1 << kWDBits);  wdk = allocU8(1 << kWDBits)
    spp = allocI16(1 << kSPBits, 2048);      spc = allocU8(1 << kSPBits);  spk = allocU8(1 << kSPBits)
    alp = allocI16(8 * 2 * 15, 2048);        alc = allocU8(8 * 2 * 15)
    o8p = allocI16(1 << kO8Bits, 2048);      o8c = allocU8(1 << kO8Bits);  o8k = allocU8(1 << kO8Bits)
    o12p = allocI16(1 << kO12Bits, 2048);    o12c = allocU8(1 << kO12Bits); o12k = allocU8(1 << kO12Bits)
    mmtab = allocU32(1 << kMMBits)
    mmp = allocI16(16, 2048);                mmc = allocU8(16)
    wx = allocInt(64 * kNModels, 65536 / kNModels)
    st = allocInt(kNModels, 0)
    apm = UnsafeMutablePointer<Int16>.allocate(capacity: 256 * 33)
    apm2 = UnsafeMutablePointer<Int16>.allocate(capacity: 32 * 33)
    for c in 0..<256 {
      for i in 0..<33 {
        let d = max(-2047, min(2047, (i - 16) * 128))
        apm[c * 33 + i] = Sigmoid.squash[d + 2047]
      }
    }
    for c in 0..<32 {
      for i in 0..<33 {
        let d = max(-2047, min(2047, (i - 16) * 128))
        apm2[c * 33 + i] = Sigmoid.squash[d + 2047]
      }
    }
    bufCapacity = max(1, capacity)
    buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufCapacity)
  }

  func free() {
    o0p.deallocate(); o0c.deallocate()
    o1p.deallocate(); o1c.deallocate()
    o2p.deallocate(); o2c.deallocate()
    o3p.deallocate(); o3c.deallocate(); o3k.deallocate()
    o4p.deallocate(); o4c.deallocate(); o4k.deallocate()
    o6p.deallocate(); o6c.deallocate(); o6k.deallocate()
    wdp.deallocate(); wdc.deallocate(); wdk.deallocate()
    spp.deallocate(); spc.deallocate(); spk.deallocate()
    alp.deallocate(); alc.deallocate()
    o8p.deallocate(); o8c.deallocate(); o8k.deallocate()
    o12p.deallocate(); o12c.deallocate(); o12k.deallocate()
    mmtab.deallocate()
    mmp.deallocate(); mmc.deallocate()
    wx.deallocate(); st.deallocate()
    apm.deallocate(); apm2.deallocate()
    buf.deallocate()
  }

  @inline(__always)
  func predict(node: Int, depth: Int) -> Int {
    let hi = isHigh
    i0 = hi * 15 + node - 1
    i1 = (Int(hist & 0xFF) << 1 | hi) * 15 + node - 1
    i2 = (Int(hist & 0xFFFF) << 1 | hi) * 15 + node - 1
    let f3 = UInt32(truncatingIfNeeded: hist & 0xFF_FFFF) &* 0x9E37_79B1
             &+ UInt32(node) &* 0x85EB_CA77
             &+ UInt32(hi) &* 0xC2B2_AE3D
    let f4 = UInt32(truncatingIfNeeded: hist) &* 0x27D4_EB2F
             &+ UInt32(node) &* 0x1656_67B1
             &+ UInt32(hi) &* 0x9E37_79B1
    let f6 = (hist & 0xFFFF_FFFF_FFFF) &* 0x9E37_79B9_7F4A_7C15
             &+ UInt64(node) &* 0x1656_67B1
             &+ UInt64(hi) &* 0x27D4_EB2F
    let fw = wordHash &* 0xB529_7A4D
             &+ UInt32(node) &* 0x68E3_1DA4
             &+ UInt32(hi) &* 0x1B56_C4E9
    let n = bufCount
    let s2: UInt32 = n >= 2 ? UInt32(buf[n - 2]) : 0
    let s4: UInt32 = n >= 4 ? UInt32(buf[n - 4]) : 0
    let fs = (s2 << 8 | s4) &* 0x9E37_79B1
             &+ UInt32(node) &* 0x27D4_EB2F
             &+ UInt32(hi) &* 0x85EB_CA77
    let f8 = hist &* 0xFF51_AFD7_ED55_8CCD
             &+ UInt64(node) &* 0xC4CE_B9FE_1A85_EC53
             &+ UInt64(hi) &* 0x9E37_79B9
    let f12 = hist &* 0x2545_F491_4F6C_DD1D
              &+ histHi &* 0x9E37_79B9_7F4A_7C15
              &+ UInt64(node) &* 0x85EB_CA77
              &+ UInt64(hi) &* 0x27D4_EB2F

    h3 = Int(f3 >> (32 - kO3Bits))
    h4 = Int(f4 >> (32 - kO4Bits))
    h6 = Int(f6 >> (64 - kO6Bits))
    hw = Int(fw >> (32 - kWDBits))
    hs = Int(fs >> (32 - kSPBits))
    h8 = Int(f8 >> (64 - kO8Bits))
    h12 = Int(f12 >> (64 - kO12Bits))
    ia = (((n & 7) << 1) | hi) * 15 + node - 1

    let k3 = UInt8(truncatingIfNeeded: f3)
    if o3k[h3] != k3 { o3p[h3] = 2048; o3c[h3] = 0; o3k[h3] = k3 }
    let k4 = UInt8(truncatingIfNeeded: f4)
    if o4k[h4] != k4 { o4p[h4] = 2048; o4c[h4] = 0; o4k[h4] = k4 }
    let k6 = UInt8(truncatingIfNeeded: f6)
    if o6k[h6] != k6 { o6p[h6] = 2048; o6c[h6] = 0; o6k[h6] = k6 }
    let kw = UInt8(truncatingIfNeeded: fw)
    if wdk[hw] != kw { wdp[hw] = 2048; wdc[hw] = 0; wdk[hw] = kw }
    let ks = UInt8(truncatingIfNeeded: fs)
    if spk[hs] != ks { spp[hs] = 2048; spc[hs] = 0; spk[hs] = ks }
    let k8 = UInt8(truncatingIfNeeded: f8)
    if o8k[h8] != k8 { o8p[h8] = 2048; o8c[h8] = 0; o8k[h8] = k8 }
    let k12 = UInt8(truncatingIfNeeded: f12)
    if o12k[h12] != k12 { o12p[h12] = 2048; o12c[h12] = 0; o12k[h12] = k12 }

    st[0] = Int(Sigmoid.stretch[Int(o0p[i0])])
    st[1] = Int(Sigmoid.stretch[Int(o1p[i1])])
    st[2] = Int(Sigmoid.stretch[Int(o2p[i2])])
    st[3] = Int(Sigmoid.stretch[Int(o3p[h3])])
    st[4] = Int(Sigmoid.stretch[Int(o4p[h4])])
    st[5] = Int(Sigmoid.stretch[Int(o6p[h6])])
    st[6] = Int(Sigmoid.stretch[Int(wdp[hw])])
    st[7] = Int(Sigmoid.stretch[Int(spp[hs])])

    mmBucket = -1
    mmExpectedBit = 0
    if matchLen > 0 && matchPtr < n {
      let e = Int(buf[matchPtr])
      let en = hi == 1 ? (e >> 4) : (e & 0xF)
      if node == (1 << depth) | (en >> (4 - depth)) {
        mmBucket = min(matchLen, 15)
        mmExpectedBit = (en >> (3 - depth)) & 1
      }
    }
    if mmBucket >= 0 {
      let s = Int(Sigmoid.stretch[Int(mmp[mmBucket])])
      st[8] = mmExpectedBit == 1 ? s : -s
    } else {
      st[8] = 0
    }

    st[9]  = Int(Sigmoid.stretch[Int(alp[ia])])
    st[10] = Int(Sigmoid.stretch[Int(o8p[h8])])
    st[11] = Int(Sigmoid.stretch[Int(o12p[h12])])

    mctx = ((Int(hist & 0xF) << 2) | (hi << 1) | (matchLen > 0 ? 1 : 0))
           * kNModels
    var dot = 0
    for i in 0..<kNModels {
      dot &+= st[i] &* wx[mctx + i]
    }
    dot >>= 16
    if dot > 2047 { dot = 2047 } else if dot < -2047 { dot = -2047 }
    pMix = Int(Sigmoid.squash[dot + 2047])

    let actx = Int(hist & 0xFF) * 33
    let s = Int(Sigmoid.stretch[pMix]) + 2048
    var j = s >> 7
    let w = s & 127
    if j > 31 { j = 31 }
    apmJ = actx + j
    let pa = (Int(apm[apmJ]) * (128 - w) + Int(apm[apmJ + 1]) * w) >> 7
    var p1 = (pMix + 3 * pa) >> 2
    if p1 < 1 { p1 = 1 } else if p1 > 4095 { p1 = 4095 }

    let a2ctx = ((min(matchLen, 15) << 1) | hi) * 33
    let sq2 = Int(Sigmoid.stretch[p1]) + 2048
    var j2 = sq2 >> 7
    let w2 = sq2 & 127
    if j2 > 31 { j2 = 31 }
    apm2J = a2ctx + j2
    let pb = (Int(apm2[apm2J]) * (128 - w2) + Int(apm2[apm2J + 1]) * w2) >> 7
    var pFinal = (p1 + 3 * pb) >> 2
    if pFinal < 1 { pFinal = 1 } else if pFinal > 4095 { pFinal = 4095 }
    return pFinal
  }

  @inline(__always)
  func update(bit: Int) {
    let t12 = bit << 12

    var c = Int(o0c[i0])
    o0p[i0] = Int16(Int(o0p[i0]) + ((t12 - Int(o0p[i0])) >> kRate[c]))
    if c < 15 { o0c[i0] = UInt8(c + 1) }
    c = Int(o1c[i1])
    o1p[i1] = Int16(Int(o1p[i1]) + ((t12 - Int(o1p[i1])) >> kRate[c]))
    if c < 15 { o1c[i1] = UInt8(c + 1) }
    c = Int(o2c[i2])
    o2p[i2] = Int16(Int(o2p[i2]) + ((t12 - Int(o2p[i2])) >> kRate[c]))
    if c < 15 { o2c[i2] = UInt8(c + 1) }
    c = Int(o3c[h3])
    o3p[h3] = Int16(Int(o3p[h3]) + ((t12 - Int(o3p[h3])) >> kRate[c]))
    if c < 15 { o3c[h3] = UInt8(c + 1) }
    c = Int(o4c[h4])
    o4p[h4] = Int16(Int(o4p[h4]) + ((t12 - Int(o4p[h4])) >> kRate[c]))
    if c < 15 { o4c[h4] = UInt8(c + 1) }
    c = Int(o6c[h6])
    o6p[h6] = Int16(Int(o6p[h6]) + ((t12 - Int(o6p[h6])) >> kRate[c]))
    if c < 15 { o6c[h6] = UInt8(c + 1) }
    c = Int(wdc[hw])
    wdp[hw] = Int16(Int(wdp[hw]) + ((t12 - Int(wdp[hw])) >> kRate[c]))
    if c < 15 { wdc[hw] = UInt8(c + 1) }
    c = Int(spc[hs])
    spp[hs] = Int16(Int(spp[hs]) + ((t12 - Int(spp[hs])) >> kRate[c]))
    if c < 15 { spc[hs] = UInt8(c + 1) }
    c = Int(alc[ia])
    alp[ia] = Int16(Int(alp[ia]) + ((t12 - Int(alp[ia])) >> kRate[c]))
    if c < 15 { alc[ia] = UInt8(c + 1) }
    c = Int(o8c[h8])
    o8p[h8] = Int16(Int(o8p[h8]) + ((t12 - Int(o8p[h8])) >> kRate[c]))
    if c < 15 { o8c[h8] = UInt8(c + 1) }
    c = Int(o12c[h12])
    o12p[h12] = Int16(Int(o12p[h12]) + ((t12 - Int(o12p[h12])) >> kRate[c]))
    if c < 15 { o12c[h12] = UInt8(c + 1) }

    if mmBucket >= 0 {
      let hitv = bit == mmExpectedBit ? 4096 : 0
      let cb = Int(mmc[mmBucket])
      mmp[mmBucket] = Int16(Int(mmp[mmBucket]) + ((hitv - Int(mmp[mmBucket])) >> kRate[cb]))
      if cb < 15 { mmc[mmBucket] = UInt8(cb + 1) }
      if bit != mmExpectedBit { matchLen = 0 }
    }

    let err = t12 - pMix
    for i in 0..<kNModels {
      var w = wx[mctx + i] + ((st[i] * err) >> kLearnShift)
      if w > (1 << 20) { w = 1 << 20 } else if w < -(1 << 20) { w = -(1 << 20) }
      wx[mctx + i] = w
    }

    apm[apmJ]     = Int16(Int(apm[apmJ])     + ((t12 - Int(apm[apmJ]))     >> kAPMRate))
    apm[apmJ + 1] = Int16(Int(apm[apmJ + 1]) + ((t12 - Int(apm[apmJ + 1])) >> kAPMRate))
    apm2[apm2J]     = Int16(Int(apm2[apm2J])     + ((t12 - Int(apm2[apm2J]))     >> kAPMRate))
    apm2[apm2J + 1] = Int16(Int(apm2[apm2J + 1]) + ((t12 - Int(apm2[apm2J + 1])) >> kAPMRate))
  }

  @inline(__always)
  func pushNibble(_ v: Int) {
    histHi = ((histHi << 4) | (hist >> 60)) & 0xFFFF_FFFF
    hist = (hist << 4) | UInt64(v)
    if isHigh == 1 {
      pendingHigh = v
      isHigh = 0
    } else {
      let byte = UInt8((pendingHigh << 4) | v)
      if bufCount < bufCapacity {
        buf[bufCount] = byte
        bufCount += 1
      }
      isHigh = 1
      if (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) {
        wordHash = wordHash &* 271 &+ UInt32(byte | 0x20)
      } else {
        wordHash = 0
      }
      matchUpdate()
    }
  }

  private func matchUpdate() {
    let n = bufCount
    if matchLen > 0 {
      if buf[n - 1] == buf[matchPtr] {
        matchPtr += 1
        matchLen += 1
      } else {
        matchLen = 0
      }
    }
    if n >= kMatchMin {
      var h: UInt32 = 0
      for k in 0..<kMatchMin {
        h = h &* 0x9E37_79B1 &+ UInt32(buf[n - 1 - k]) &+ 1
      }
      let idx = Int(h >> (32 - kMMBits))
      if matchLen == 0 {
        let cand = Int(mmtab[idx])
        if cand > 0 && cand < n {
          matchPtr = cand
          matchLen = 1
        }
      }
      mmtab[idx] = UInt32(n)
    }
  }

  @inline(__always)
  func codeNibble(_ v: Int, rc: inout CMERangeEncoder) {
    var node = 1
    for depth in 0..<4 {
      let p = predict(node: node, depth: depth)
      let bit = (v >> (3 - depth)) & 1
      rc.encode(4096 - p, bit)
      update(bit: bit)
      node = (node << 1) | bit
    }
    pushNibble(v)
  }

  @inline(__always)
  func decodeNibble(rc: inout CMERangeDecoder) {
    var node = 1
    for depth in 0..<4 {
      let p = predict(node: node, depth: depth)
      let bit = rc.decode(4096 - p)
      update(bit: bit)
      node = (node << 1) | bit
    }
    pushNibble(node - 16)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – BEN_CME
// ─────────────────────────────────────────────────────────────────────────────

public enum BEN_CME {

  public static func compress(_ input: Data, unsafeCoder: Bool = false) throws -> Data {
    guard UInt64(input.count) <= UInt64(UInt32.max) else {
      throw BEN_CMEError.fileTooLarge
    }
    let byteCount = UInt32(input.count)

    var out = Data()
    out.append(UInt8((byteCount >> 24) & 0xFF))
    out.append(UInt8((byteCount >> 16) & 0xFF))
    out.append(UInt8((byteCount >>  8) & 0xFF))
    out.append(UInt8( byteCount        & 0xFF))
    if input.isEmpty { return out }

    var rc = CMERangeEncoder()
    if unsafeCoder {
      let model = CMEModelU(capacity: input.count)
      defer { model.free() }
      for byte in input {
        model.codeNibble(Int(byte >> 4), rc: &rc)
        model.codeNibble(Int(byte & 0x0F), rc: &rc)
      }
    } else {
      let model = CMEModel()
      model.buf.reserveCapacity(input.count)

      @inline(__always)
      func codeNibble(_ v: Int) {
        var node = 1
        for depth in 0..<4 {
          let p = model.predict(node: node, depth: depth)
          let bit = (v >> (3 - depth)) & 1
          rc.encode(4096 - p, bit)
          model.update(bit: bit)
          node = (node << 1) | bit
        }
        model.pushNibble(v)
      }
      for byte in input {
        codeNibble(Int(byte >> 4))
        codeNibble(Int(byte & 0x0F))
      }
    }
    rc.flush()

    out.append(contentsOf: rc.output)
    return out
  }

  public static func decompress(_ compressed: Data, unsafeCoder: Bool = false) throws -> Data {
    let raw = Array(compressed)
    guard raw.count >= 4 else {
      throw BEN_CMEError.invalidData("Header zu kurz (\(raw.count) < 4 Bytes)")
    }
    let byteCount = UInt32(raw[0]) << 24 | UInt32(raw[1]) << 16
                  | UInt32(raw[2]) << 8 | UInt32(raw[3])
    if byteCount == 0 { return Data() }

    var rc = CMERangeDecoder(data: raw, startPos: 4)

    if unsafeCoder {
      let model = CMEModelU(capacity: Int(byteCount))
      defer { model.free() }
      for _ in 0..<(Int(byteCount) * 2) {
        model.decodeNibble(rc: &rc)
      }
      return Data(UnsafeBufferPointer(start: model.buf, count: model.bufCount))
    } else {
      let model = CMEModel()
      model.buf.reserveCapacity(min(Int(byteCount), 1 << 22))
      for _ in 0..<(Int(byteCount) * 2) {
        var node = 1
        for depth in 0..<4 {
          let p = model.predict(node: node, depth: depth)
          let bit = rc.decode(4096 - p)
          model.update(bit: bit)
          node = (node << 1) | bit
        }
        model.pushNibble(node - 16)
      }
      return Data(model.buf)
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // MARK: Self-Test
  // ───────────────────────────────────────────────────────────────────────────

  @discardableResult
  public static func selfTest(rounds: Int = 25, bytesPerRound: Int = 512) -> Bool {
    var failures = [String]()

    // Deterministischer Zufall (LCG) — Self-Test muss reproduzierbar sein.
    var lcgState: UInt64 = 0x59
    func lcg() -> UInt8 {
      lcgState = lcgState &* 6364136223846793005 &+ 1442695040888963407
      return UInt8(truncatingIfNeeded: lcgState >> 56)
    }

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
      ("4096× 0xAB",     Data(repeating: 0xAB, count: 4096)),
      ("periodisch",     Data([UInt8]((0..<4096).map { $0 % 2 == 0 ? 0x20 : 0x02 }))),
      ("Text",           Data(String(repeating: "the quick brown fox ", count: 500).utf8)),
    ]
    for (label, orig) in edgeCases { roundtrip("Grenzfall \(label)", orig) }

    for byte in 0...255 as ClosedRange<UInt8> {
      roundtrip("Byte 0x\(String(byte, radix: 16, uppercase: true))", Data([byte]))
    }

    for r in 0..<rounds {
      let orig = Data((0..<bytesPerRound).map { _ in lcg() })
      roundtrip("Runde \(r)", orig)
    }

    // Zielfall Alignment (Nr. 12/27): 32-Bit-Werte, strukturierte High-,
    // verrauschte Low-Bytes — hier muss CME deutlich unter BEN_CM liegen.
    var structNoise = Data()
    var counter = 1000
    for _ in 0..<4000 {
      counter += Int(lcg() & 0x03)
      let noise = Int(lcg()) << 8 | Int(lcg())
      let value = UInt32((counter & 0xFFFF) << 16 | noise)
      structNoise.append(UInt8(value & 0xFF))
      structNoise.append(UInt8((value >> 8) & 0xFF))
      structNoise.append(UInt8((value >> 16) & 0xFF))
      structNoise.append(UInt8((value >> 24) & 0xFF))
    }
    roundtrip("Struktur+Rauschen", structNoise)
    do {
      let cme = try compress(structNoise)
      let cm  = try BEN_CM.compress(structNoise)
      if cme.count >= cm.count {
        failures.append("Zielfall: CME schlägt ncmm nicht "
                        + "(\(cme.count) ≥ \(cm.count))")
      }
    } catch {
      failures.append("Zielfall: \(error)")
    }

    // Safe/Unsafe bitidentisch inkl. Kreuz-Dekodierung
    do {
      var mixed = structNoise.prefix(6000)
      mixed.append(Data(String(repeating: "safe gleich unsafe ", count: 200).utf8))
      let mixedData = Data(mixed)
      let safeOut   = try compress(mixedData, unsafeCoder: false)
      let unsafeOut = try compress(mixedData, unsafeCoder: true)
      if safeOut != unsafeOut {
        failures.append("safe/unsafe nicht bitidentisch")
      }
      if try decompress(safeOut, unsafeCoder: true) != mixedData {
        failures.append("Kreuz-Dekodierung (safe→unsafe) fehlgeschlagen")
      }
      if try decompress(unsafeOut, unsafeCoder: false) != mixedData {
        failures.append("Kreuz-Dekodierung (unsafe→safe) fehlgeschlagen")
      }
    } catch {
      failures.append("safe/unsafe: \(error)")
    }

    if failures.isEmpty {
      print("✅ BEN_CME Self-Test bestanden")
      print("   Grenzfälle + 256-Sweep + \(rounds) Zufallsrunden (LCG, reproduzierbar)")
      print("   Zielfall-Gewinn vs. ncmm + safe/unsafe bitidentisch: verifiziert ✓")
      print("   Pipeline: Context Mixing (o0–o12, Alignment, Wort, Sparse, Match) ✓")
    } else {
      print("❌ BEN_CME FEHLGESCHLAGEN (\(failures.count) Fehler):")
      failures.prefix(8).forEach { print("   \($0)") }
    }
    return failures.isEmpty
  }
}
