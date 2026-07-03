// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Sebastian Ritter <bastie@users.noreply.github.com>

/*
 * BEN_CM – Context-Mixing-Coder auf Nibble-Ebene (ohne BWT)
 *
 * Grundidee:
 *   Auswertung der impliziten Informationen einer Datei direkt am
 *   Nibble-Strom — ohne Transformation:
 *
 *   1. KONTEXT: die vorangehenden Nibbles mehrerer Ordnungen
 *      (Order-0/1/2/3/4 sowie 6 Bytes) — die Markov-Kette der Projektidee,
 *      verallgemeinert auf mehrere Tiefen gleichzeitig.
 *   2. POSITION IM BYTE: Hi- und Lo-Nibble haben völlig verschiedene
 *      Verteilungen (Parität der Position ist implizite Information).
 *   3. POSITION DES LETZTEN AUFTRETENS: ein Match-Modell erinnert, wo
 *      derselbe Byte-Kontext zuletzt stand, und sagt die Fortsetzung
 *      voraus — die Werte-Position als implizite Information; der
 *      Match-Status konditioniert zusätzlich Mixer und APM.
 *
 *   4. WORT-KONTEXT: Hash der laufenden Buchstabenfolge (Text).
 *   5. SPARSE-KONTEXT: Byte[-2]/Byte[-4] — Alignment in Binärstrukturen.
 *
 *   Jedes Nibble wird als 4 binäre Entscheidungen kodiert (Baum).
 *   Neun Vorhersagen werden per logistischem Mixing (Integer-Festkomma)
 *   kombiniert, zwei APM/SSE-Stufen verfeinern das Ergebnis.
 *   Hash-Slots tragen 8-Bit-Prüfsummen: erkannte Kollisionen setzen den
 *   Slot zurück, statt fremde Statistik zu vergiften (wichtig ab ~MB-Größe).
 *
 * Eigenschaften:
 *   - vollständig bijektiv: Decoder führt das identische Modell vorwärts
 *   - rein Integer (eingebettete Sigmoid-Stützstellen) → plattform-
 *     unabhängig deterministisch, kein Float
 *   - Ein-Pass, adaptiv, kein BWT → kein Suffix-Array-Aufbau
 *
 * Format:
 *   [4B byteCount BE] [Range-Coder-Strom]
 *
 * Portierungs-Verifikation:
 *   Design als Python-Referenz validiert (Roundtrips + Ratio: schlägt
 *   bz2 und lzma auf dem Projekt-Korpus). Diese Implementierung spiegelt
 *   die Referenz; selfTest() prüft Bijektivität erneut in Swift.
 */

import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Fehlertypen
// ─────────────────────────────────────────────────────────────────────────────

public enum BEN_CMError: Error, CustomStringConvertible, Sendable {
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

/// Hash-Tabellengrößen (Bits). Größer = weniger Kollisionen = bessere Ratio.
/// Ausgelegt auf Dateien im 100-MB-Bereich (~450 MB Tabellenspeicher).
private let kO3Bits = 24
private let kO4Bits = 25
private let kO6Bits = 25
private let kWDBits = 24
private let kSPBits = 22
private let kMMBits = 24
/// Mixer-Lernrate (empirisch: 9 optimal auf dem Projekt-Korpus).
private let kLearnShift = 9
/// Mindestlänge des Match-Kontexts in Bytes.
private let kMatchMin = 5
/// APM-Adaptionsrate.
private let kAPMRate = 6
/// Adaptionsraten je Zählerstand (schnell → langsam).
private let kRate: [Int] = [2, 2, 3, 3, 4, 4, 4, 5, 5, 5, 6, 6, 6, 6, 7, 7]

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Sigmoid (rein Integer, eingebettete Stützstellen)
// ─────────────────────────────────────────────────────────────────────────────

private enum Sigmoid {

  /// Stützstellen von 4096/(1+e^(-x/256)) bei x = -2048...2048, Schritt 128.
  /// Eingebettet als Konstanten — identisch zur validierten Referenz.
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

  /// squash-Tabelle: Index d+2047, d ∈ -2047...2047.
  static let squash: [Int16] = (-2047...2047).map { Int16(rawSquash($0)) }

  /// stretch = Umkehrung, rein Integer abgeleitet.
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
// MARK: – Range-Coder (12-Bit-Wahrscheinlichkeit als Parameter)
// ─────────────────────────────────────────────────────────────────────────────

private struct CMRangeEncoder {

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

private struct CMRangeDecoder {

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
// MARK: – Context-Mixing-Modell
// ─────────────────────────────────────────────────────────────────────────────

/// Gemeinsamer Modellzustand von Encoder und Decoder (Referenztyp:
/// große Tabellen ohne COW-Kopien). Beide Seiten führen exakt dieselben
/// Updates aus → Bijektivität.
private final class CMModel {

  static let nModels = 9

  // Kontexttabellen: Wahrscheinlichkeit P(bit==1) in 12 Bit + Zähler
  var o0p = [Int16](repeating: 2048, count: 2 * 15)
  var o0c = [UInt8](repeating: 0, count: 2 * 15)
  var o1p = [Int16](repeating: 2048, count: 512 * 15)
  var o1c = [UInt8](repeating: 0, count: 512 * 15)
  var o2p = [Int16](repeating: 2048, count: 131_072 * 15)
  var o2c = [UInt8](repeating: 0, count: 131_072 * 15)
  // Hash-Modelle: Wahrscheinlichkeit + Zähler + Prüfsumme (Kollisionsschutz)
  var o3p = [Int16](repeating: 2048, count: 1 << kO3Bits)
  var o3c = [UInt8](repeating: 0, count: 1 << kO3Bits)
  var o3k = [UInt8](repeating: 0, count: 1 << kO3Bits)
  var o4p = [Int16](repeating: 2048, count: 1 << kO4Bits)
  var o4c = [UInt8](repeating: 0, count: 1 << kO4Bits)
  var o4k = [UInt8](repeating: 0, count: 1 << kO4Bits)
  var o6p = [Int16](repeating: 2048, count: 1 << kO6Bits)
  var o6c = [UInt8](repeating: 0, count: 1 << kO6Bits)
  var o6k = [UInt8](repeating: 0, count: 1 << kO6Bits)
  // Wort-Modell (Buchstabenfolge seit letztem Trennzeichen)
  var wdp = [Int16](repeating: 2048, count: 1 << kWDBits)
  var wdc = [UInt8](repeating: 0, count: 1 << kWDBits)
  var wdk = [UInt8](repeating: 0, count: 1 << kWDBits)
  // Sparse-Modell (Byte[-2], Byte[-4] — Alignment in Binärstrukturen)
  var spp = [Int16](repeating: 2048, count: 1 << kSPBits)
  var spc = [UInt8](repeating: 0, count: 1 << kSPBits)
  var spk = [UInt8](repeating: 0, count: 1 << kSPBits)

  // Match-Modell
  var mmtab = [UInt32](repeating: 0, count: 1 << kMMBits)  // Position+0 des Folge-Bytes
  var buf = [UInt8]()
  var matchPtr = 0
  var matchLen = 0
  var mmp = [Int16](repeating: 2048, count: 16)            // P(Bit == erwartet) je Längen-Bucket
  var mmc = [UInt8](repeating: 0, count: 16)

  // Mixer: 64 Gewichtssätze (Nibble × Parität × Match aktiv) × nModels
  var wx = [Int](repeating: 65536 / CMModel.nModels, count: 64 * CMModel.nModels)

  // APM Stufe 1: 256 Byte-Kontexte × 33 Stützstellen
  var apm: [Int16] = CMModel.apmInit(rows: 256)
  // APM Stufe 2: 32 Match-Kontexte × 33 Stützstellen
  var apm2: [Int16] = CMModel.apmInit(rows: 32)

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

  // Verlauf
  var hist: UInt64 = 0        // letzte 16 Nibbles
  var isHigh = 1              // 1 = Hi-Nibble folgt
  var pendingHigh = 0
  var wordHash: UInt32 = 0    // Hash der laufenden Buchstabenfolge

  // Zustand des aktuellen Bits (predict → update)
  var i0 = 0, i1 = 0, i2 = 0, h3 = 0, h4 = 0, h6 = 0, hw = 0, hs = 0
  var st = [Int](repeating: 0, count: CMModel.nModels)
  var mmBucket = -1
  var mmExpectedBit = 0
  var mctx = 0
  var pMix = 2048
  var apmJ = 0
  var apm2J = 0

  // ── Vorhersage für das Bit am Baumknoten `node` in Tiefe `depth` ──────────
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
    h3 = Int(f3 >> (32 - kO3Bits))
    h4 = Int(f4 >> (32 - kO4Bits))
    h6 = Int(f6 >> (64 - kO6Bits))
    hw = Int(fw >> (32 - kWDBits))
    hs = Int(fs >> (32 - kSPBits))

    // Prüfsummen: erkannte Kollision → Slot zurücksetzen (beidseitig identisch)
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

    st[0] = stretch(Int(o0p[i0]))
    st[1] = stretch(Int(o1p[i1]))
    st[2] = stretch(Int(o2p[i2]))
    st[3] = stretch(Int(o3p[h3]))
    st[4] = stretch(Int(o4p[h4]))
    st[5] = stretch(Int(o6p[h6]))
    st[6] = stretch(Int(wdp[hw]))
    st[7] = stretch(Int(spp[hs]))

    // Match-Modell: nur solange der Bit-Pfad dem erwarteten Nibble folgt
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

    // Mixer (logistisch, Integer-Festkomma); Kontext enthält Match-Status
    mctx = ((Int(hist & 0xF) << 2) | (hi << 1) | (matchLen > 0 ? 1 : 0))
           * CMModel.nModels
    var dot = 0
    for i in 0..<CMModel.nModels {
      dot &+= st[i] &* wx[mctx + i]
    }
    dot >>= 16
    if dot > 2047 { dot = 2047 } else if dot < -2047 { dot = -2047 }
    pMix = squash(dot)

    // APM/SSE Stufe 1: Byte-Kontext
    let actx = Int(hist & 0xFF) * 33
    let s = stretch(pMix) + 2048          // 1...4095
    var j = s >> 7
    let w = s & 127
    if j > 31 { j = 31 }
    apmJ = actx + j
    let pa = (Int(apm[apmJ]) * (128 - w) + Int(apm[apmJ + 1]) * w) >> 7
    var p1 = (pMix + 3 * pa) >> 2
    if p1 < 1 { p1 = 1 } else if p1 > 4095 { p1 = 4095 }

    // APM/SSE Stufe 2: Match-Kontext
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

  // ── Modell-Anpassung nach jedem Bit ────────────────────────────────────────
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

    // Match-Konfidenz; falscher Tipp bricht den Match
    if mmBucket >= 0 {
      let hitv = bit == mmExpectedBit ? 4096 : 0
      let cb = Int(mmc[mmBucket])
      mmp[mmBucket] = Int16(Int(mmp[mmBucket]) + ((hitv - Int(mmp[mmBucket])) >> kRate[cb]))
      if cb < 15 { mmc[mmBucket] = UInt8(cb + 1) }
      if bit != mmExpectedBit { matchLen = 0 }
    }

    // Mixer-Gewichte
    let err = t12 - pMix
    for i in 0..<CMModel.nModels {
      var w = wx[mctx + i] + ((st[i] * err) >> kLearnShift)
      if w > (1 << 20) { w = 1 << 20 } else if w < -(1 << 20) { w = -(1 << 20) }
      wx[mctx + i] = w
    }

    // APM (beide Stützstellen, beide Stufen)
    apm[apmJ]     = Int16(Int(apm[apmJ])     + ((t12 - Int(apm[apmJ]))     >> kAPMRate))
    apm[apmJ + 1] = Int16(Int(apm[apmJ + 1]) + ((t12 - Int(apm[apmJ + 1])) >> kAPMRate))
    apm2[apm2J]     = Int16(Int(apm2[apm2J])     + ((t12 - Int(apm2[apm2J]))     >> kAPMRate))
    apm2[apm2J + 1] = Int16(Int(apm2[apm2J + 1]) + ((t12 - Int(apm2[apm2J + 1])) >> kAPMRate))
  }

  // ── Verlauf fortschreiben ─────────────────────────────────────────────────
  func pushNibble(_ v: Int) {
    hist = (hist << 4) | UInt64(v)
    if isHigh == 1 {
      pendingHigh = v
      isHigh = 0
    } else {
      let byte = UInt8((pendingHigh << 4) | v)
      buf.append(byte)
      isHigh = 1
      // Wort-Verlauf: Buchstaben akkumulieren, sonst zurücksetzen
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
// MARK: – BEN_CM
// ─────────────────────────────────────────────────────────────────────────────

public enum BEN_CM {

  // ───────────────────────────────────────────────────────────────────────────
  // MARK: Komprimieren
  // ───────────────────────────────────────────────────────────────────────────

  public static func compress(_ input: Data) throws -> Data {
    guard UInt64(input.count) <= UInt64(UInt32.max) else {
      throw BEN_CMError.fileTooLarge
    }
    let byteCount = UInt32(input.count)

    var out = Data()
    out.append(UInt8((byteCount >> 24) & 0xFF))
    out.append(UInt8((byteCount >> 16) & 0xFF))
    out.append(UInt8((byteCount >>  8) & 0xFF))
    out.append(UInt8( byteCount        & 0xFF))
    if input.isEmpty { return out }

    let model = CMModel()
    model.buf.reserveCapacity(input.count)
    var rc = CMRangeEncoder()

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
    rc.flush()

    out.append(contentsOf: rc.output)
    return out
  }

  // ───────────────────────────────────────────────────────────────────────────
  // MARK: Dekomprimieren
  // ───────────────────────────────────────────────────────────────────────────

  public static func decompress(_ compressed: Data) throws -> Data {
    let raw = Array(compressed)
    guard raw.count >= 4 else {
      throw BEN_CMError.invalidData("Header zu kurz (\(raw.count) < 4 Bytes)")
    }
    let byteCount = UInt32(raw[0]) << 24 | UInt32(raw[1]) << 16
                  | UInt32(raw[2]) << 8 | UInt32(raw[3])
    if byteCount == 0 { return Data() }

    let model = CMModel()
    model.buf.reserveCapacity(min(Int(byteCount), 1 << 22))
    var rc = CMRangeDecoder(data: raw, startPos: 4)

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

  // ───────────────────────────────────────────────────────────────────────────
  // MARK: Self-Test
  // ───────────────────────────────────────────────────────────────────────────

  @discardableResult
  public static func selfTest(rounds: Int = 50, bytesPerRound: Int = 512) -> Bool {
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
      if c.count * 4 > text.count {
        failures.append("Ratio: Text nicht < 25 % (\(c.count)/\(text.count))")
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
      print("✅ BEN_CM Self-Test bestanden")
      print("   \(rounds) Runden × \(bytesPerRound)B + 256-Sweep + \(edgeCases.count) Grenzfälle")
      print("   + Regressionstest (10K, 100K, 1MB) + Ratio-Checks")
      print("   Bijektivität: verifiziert ✓")
      print("   Pipeline: Bytes → Nibbles → Context Mixing (o0–o4, Parität, Match) ✓")
    } else {
      print("❌ BEN_CM FEHLGESCHLAGEN (\(failures.count) Fehler):")
      failures.prefix(8).forEach { print("   \($0)") }
    }
    return failures.isEmpty
  }
}
