// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Sebastian Ritter <bastie@users.noreply.github.com>

/*
 * NibblePlanarDeltaFilter – bijektive Vorverarbeitung für Binärdaten
 * (Katalog Nr. 53, Auswahl per Wettbewerb Nr. 54)
 *
 * Zwei unabhängige, exakt umkehrbare Transformationen VOR der BWT:
 *
 *   1. Wrapping-Delta mit Stride s ∈ {1, 2, 4, 8}: jedes Byte wird durch
 *      die Differenz zu seinem Vorgänger im Abstand s ersetzt (mod 256,
 *      Swift &- / &+). Glättet Arrays numerischer Werte (16/32/64 Bit,
 *      Zähler, Messreihen) — die Permutations-Blöcke der Kernidee werden
 *      dadurch länger und geburtstags-günstiger.
 *
 *   2. Nibble-Planarisierung: statt High,Low,High,Low,… interleaved werden
 *      alle High-Nibbles vor alle Low-Nibbles sortiert. Trennt Struktur
 *      (High: Flags, Befehlsgruppen, führende Nullen) vom Rauschen
 *      (Low: Adressen, Messwert-Feinanteile), bevor die BWT den Kontext
 *      bildet — das Rauschen der Low-Nibbles zerstört sonst den Kontext
 *      der High-Nibbles.
 *
 * WICHTIG (gemessen, Python-Referenz ben_nbcm10_proto.py): beide Filter
 * helfen NUR auf passenden Daten und schaden auf Text massiv (bis +56 %).
 * Deshalb entscheidet nie eine Heuristik allein, sondern der Wettbewerb:
 * jede Variante wird tatsächlich komprimiert, die kleinste Ausgabe gewinnt
 * (BEN_NBCMBF). Die Entropie-Heuristik hier wählt nur den Stride-KANDIDATEN
 * vor, damit nicht alle vier Strides komprimiert werden müssen.
 *
 * Determinismus: die Heuristik rechnet in reiner Integer-Festkomma-
 * Arithmetik (log2 × 256, linear interpoliert) — bewusst KEIN Float
 * (libm-log2 ist nicht plattformidentisch, die Variantenwahl und damit
 * der Ausgabestrom müssen es aber sein). Gegenprobe gegen die
 * Float-Referenz: identische Wahl auf allen sieben Testkorpora.
 *
 * Safe/Unsafe: alle heißen Schleifen existieren doppelt — einmal mit
 * normalen Array-Zugriffen (Bounds-Checks), einmal über rohe
 * Buffer-Pointer. Auswahl über denselben unsafeCoder-Schalter wie beim
 * Coder; beide Pfade liefern bitidentische Ergebnisse (Test erzwingt das).
 */

import Foundation

package enum NibblePlanarDeltaFilter {

  /// Erlaubte Strides für den Delta-Filter (0 = kein Delta).
  package static let validStrides: [Int] = [1, 2, 4, 8]

  /// Bit im Filter-Byte: Nibble-Planarisierung aktiv.
  package static let planarFlag: UInt8 = 0x80

  // ─────────────────────────────────────────────────────────────────────────
  // MARK: Filter-Byte (Blockheader, 1 Byte)
  // ─────────────────────────────────────────────────────────────────────────

  /// Layout: Bits 0–3 = Stride (0, 1, 2, 4, 8), Bit 7 = Planarisierung.
  package static func makeInfoByte(stride: Int, planar: Bool) -> UInt8 {
    var b = UInt8(stride & 0x0F)
    if planar { b |= planarFlag }
    return b
  }

  /// Zerlegt und validiert das Filter-Byte. `nil` bei ungültigem Inhalt
  /// (unbekannte Flag-Bits oder Stride ∉ {0,1,2,4,8}) — der Aufrufer
  /// entscheidet über den Fehlertyp.
  package static func parseInfoByte(_ b: UInt8) -> (stride: Int, planar: Bool)? {
    let flags = b & 0xF0
    guard flags == 0 || flags == planarFlag else { return nil }
    let stride = Int(b & 0x0F)
    guard stride == 0 || validStrides.contains(stride) else { return nil }
    return (stride, flags == planarFlag)
  }

  // ─────────────────────────────────────────────────────────────────────────
  // MARK: Wrapping-Delta (in-place, bijektiv)
  // ─────────────────────────────────────────────────────────────────────────

  /// Ersetzt jedes Byte durch die Differenz zu seinem Vorgänger im Abstand
  /// `stride` (mod 256). Rückwärts iteriert, damit der Referenzwert noch
  /// unverändert ist, wenn er gebraucht wird.
  package static func deltaEncode(_ data: inout [UInt8], stride: Int,
                                  unsafeVariant: Bool = false) {
    guard stride > 0, data.count > stride else { return }
    if unsafeVariant {
      data.withUnsafeMutableBufferPointer { buf in
        var i = buf.count - 1
        while i >= stride {
          buf[i] = buf[i] &- buf[i - stride]
          i -= 1
        }
      }
    } else {
      var i = data.count - 1
      while i >= stride {
        data[i] = data[i] &- data[i - stride]
        i -= 1
      }
    }
  }

  /// Umkehrung von `deltaEncode`. Vorwärts iteriert: der Vorgänger ist
  /// bereits rekonstruiert, wenn er gebraucht wird.
  package static func deltaDecode(_ data: inout [UInt8], stride: Int,
                                  unsafeVariant: Bool = false) {
    guard stride > 0, data.count > stride else { return }
    if unsafeVariant {
      data.withUnsafeMutableBufferPointer { buf in
        var i = stride
        while i < buf.count {
          buf[i] = buf[i] &+ buf[i - stride]
          i += 1
        }
      }
    } else {
      var i = stride
      while i < data.count {
        data[i] = data[i] &+ data[i - stride]
        i += 1
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // MARK: Nibble-Planarisierung (bijektive Permutation)
  // ─────────────────────────────────────────────────────────────────────────

  /// [h0,l0,h1,l1,…] → [h0,h1,…,l0,l1,…]. Erwartet gerade Länge
  /// (Nibble-Ströme aus Bytes sind immer gerade).
  package static func planarize(_ nibbles: [UInt8],
                                unsafeVariant: Bool = false) -> [UInt8] {
    let n = nibbles.count
    assert(n % 2 == 0, "Nibble-Strom mit ungerader Länge")
    guard n >= 4 else { return nibbles }
    let half = n / 2
    var out = [UInt8](repeating: 0, count: n)
    if unsafeVariant {
      nibbles.withUnsafeBufferPointer { src in
        out.withUnsafeMutableBufferPointer { dst in
          var k = 0
          while k < half {
            dst[k]        = src[2 * k]
            dst[half + k] = src[2 * k + 1]
            k += 1
          }
        }
      }
    } else {
      var k = 0
      while k < half {
        out[k]        = nibbles[2 * k]
        out[half + k] = nibbles[2 * k + 1]
        k += 1
      }
    }
    return out
  }

  /// Umkehrung von `planarize`.
  package static func deplanarize(_ nibbles: [UInt8],
                                  unsafeVariant: Bool = false) -> [UInt8] {
    let n = nibbles.count
    assert(n % 2 == 0, "Nibble-Strom mit ungerader Länge")
    guard n >= 4 else { return nibbles }
    let half = n / 2
    var out = [UInt8](repeating: 0, count: n)
    if unsafeVariant {
      nibbles.withUnsafeBufferPointer { src in
        out.withUnsafeMutableBufferPointer { dst in
          var k = 0
          while k < half {
            dst[2 * k]     = src[k]
            dst[2 * k + 1] = src[half + k]
            k += 1
          }
        }
      }
    } else {
      var k = 0
      while k < half {
        out[2 * k]     = nibbles[k]
        out[2 * k + 1] = nibbles[half + k]
        k += 1
      }
    }
    return out
  }

  // ─────────────────────────────────────────────────────────────────────────
  // MARK: Stride-Vorauswahl (deterministische Integer-Entropie-Heuristik)
  // ─────────────────────────────────────────────────────────────────────────

  /// log2(x) in 8-Bit-Festkomma (Ergebnis = log2(x)·256, linear
  /// interpoliert über die 8 Bits unter dem MSB). Monoton, rein Integer,
  /// plattformdeterministisch. Maximaler Fehler ≈ 0,086 Bit — für eine
  /// Vorauswahl mehr als ausreichend (die Endauswahl trifft ohnehin der
  /// Wettbewerb über die reale Ausgabegröße).
  @inline(__always)
  package static func log2Fixed(_ x: Int) -> Int {
    precondition(x > 0)
    let msb = 63 - x.leadingZeroBitCount
    let frac: Int
    if msb >= 8 {
      frac = (x >> (msb - 8)) & 0xFF
    } else {
      frac = (x << (8 - msb)) & 0xFF
    }
    return (msb << 8) + frac
  }

  /// Geschätzte Kodierkosten (Bits·256) eines Byte-Histogramms:
  /// n·log2(n) − Σ c·log2(c). Ordnungs-0-Schätzer — genügt, um zu
  /// erkennen, ob ein Delta die Verteilung konzentriert.
  @inline(__always)
  private static func entropyCost(_ hist: [Int], total: Int) -> Int {
    guard total > 0 else { return 0 }
    var sum = 0
    for c in hist where c > 0 {
      sum += c * log2Fixed(c)
    }
    return total * log2Fixed(total) - sum
  }

  /// Wählt den Delta-Stride-KANDIDATEN (0 = kein Delta) über die
  /// Ordnungs-0-Entropie der Delta-Verteilung. Nur Vorauswahl — die
  /// endgültige Entscheidung trifft der Wettbewerb in BEN_NBCMBF.
  /// Deterministisch: feste Prüfreihenfolge, strikt-kleiner-Vergleich.
  package static func chooseStride(_ data: [UInt8],
                                   unsafeVariant: Bool = false) -> Int {
    let n = data.count
    guard n > 8 else { return 0 }

    func rawHistogram() -> [Int] {
      var h = [Int](repeating: 0, count: 256)
      if unsafeVariant {
        data.withUnsafeBufferPointer { src in
          h.withUnsafeMutableBufferPointer { hist in
            var i = 0
            while i < n {
              hist[Int(src[i])] += 1
              i += 1
            }
          }
        }
      } else {
        var i = 0
        while i < n {
          h[Int(data[i])] += 1
          i += 1
        }
      }
      return h
    }

    func deltaHistogram(_ stride: Int) -> [Int] {
      var h = [Int](repeating: 0, count: 256)
      if unsafeVariant {
        data.withUnsafeBufferPointer { src in
          h.withUnsafeMutableBufferPointer { hist in
            var i = 0
            while i < stride {
              hist[Int(src[i])] += 1
              i += 1
            }
            while i < n {
              hist[Int(src[i] &- src[i - stride])] += 1
              i += 1
            }
          }
        }
      } else {
        var i = 0
        while i < stride {
          h[Int(data[i])] += 1
          i += 1
        }
        while i < n {
          h[Int(data[i] &- data[i - stride])] += 1
          i += 1
        }
      }
      return h
    }

    var bestStride = 0
    var bestCost = entropyCost(rawHistogram(), total: n)
    for s in validStrides {
      let cost = entropyCost(deltaHistogram(s), total: n)
      if cost < bestCost {
        bestStride = s
        bestCost = cost
      }
    }
    return bestStride
  }
}
