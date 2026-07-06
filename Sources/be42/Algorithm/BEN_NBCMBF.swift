// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Sebastian Ritter <bastie@users.noreply.github.com>

/*
 * BEN_NBCMBF – BEN_NBCMB mit Nibble-Planar-Delta-Filter im Wettbewerb
 * (Katalog Nr. 53 + 54)
 *
 * Der Kern bleibt vollständig unangetastet: Markov-Kette / Geburtstags-
 * paradox, Exclusion-Ketten, Dual-Rate-Mixing, APM, Block-Modus mit
 * paralleler Kompression UND Dekompression. Neu ist ausschließlich eine
 * bijektive Vorverarbeitung VOR der BWT jedes Blocks:
 *
 *   - Wrapping-Delta (Stride 1/2/4/8): glättet numerische Binärarrays
 *   - Nibble-Planarisierung: trennt High- von Low-Nibbles, damit Rauschen
 *     in den Low-Nibbles den BWT-Kontext der High-Nibbles nicht zerstört
 *
 * Auswahl per WETTBEWERB, nicht per Heuristik (gemessen: eine Heuristik
 * allein schadet auf Text bis +56 %): pro Block werden bis zu vier
 * Varianten wirklich komprimiert — ohne Filter, nur Planarisierung, nur
 * Delta (Stride per deterministischer Integer-Entropie vorausgewählt),
 * Delta+Planarisierung — und die kleinste reale Ausgabe gewinnt. Damit ist
 * das Ergebnis PER KONSTRUKTION nie schlechter als BEN_NBCMB plus ein
 * Filter-Byte je Block. Auf dem Zielfall (32-Bit-Werte, strukturierte
 * High-, verrauschte Low-Bytes) −33 % (Python-Referenz ben_nbcm10_proto).
 *
 * Kosten: bis zu 4 Kompressionsläufe je Block (nur beim Komprimieren; die
 * Blöcke laufen weiterhin parallel). Die Dekompression dekodiert exakt
 * eine Variante und bleibt so schnell wie BEN_NBCMB.
 *
 * Format:
 *   [4B blockSize BE] [4B blockCount BE]                     (wie BEN_NBCMB)
 *   je Block: [4B compressedLength BE]
 *             [1B filterInfo] [BEN_NBCM-Block-Payload]
 *   filterInfo: Bits 0–3 = Stride (0,1,2,4,8), Bit 7 = Planarisierung
 *
 * Bijektiv: beide Filter sind exakt umkehrbar (Wrapping-Arithmetik bzw.
 * feste Permutation), die Wahl steht im Filter-Byte — der Decoder braucht
 * keine Heuristik.
 */

import Foundation

public enum BEN_NBCMBFError: Error, CustomStringConvertible, Sendable {
  case invalidData(String)

  public var description: String {
    switch self {
    case .invalidData(let m): return "Ungültige Daten: \(m)"
    }
  }
}

public enum BEN_NBCMBF {

  // ───────────────────────────────────────────────────────────────────────────
  // MARK: Öffentliche API — delegiert an das Block-Gerüst von BEN_NBCMB
  // ───────────────────────────────────────────────────────────────────────────

  public static func compress(_ input: Data,
                              blockSize: Int = BEN_NBCMB.defaultBlockSize,
                              unsafeCoder: Bool = false,
                              useGPU: Bool = false) throws -> Data {
    return try BEN_NBCMB.coreCompress(input, blockSize: blockSize,
                                      unsafeCoder: unsafeCoder, filtered: true,
                                      useGPU: useGPU)
  }

  public static func compressParallel(_ input: Data,
                                      blockSize: Int = BEN_NBCMB.defaultBlockSize,
                                      threads: Int = 0,
                                      unsafeCoder: Bool = false,
                                      useGPU: Bool = false) async throws -> Data {
    return try await BEN_NBCMB.coreCompressParallel(input, blockSize: blockSize,
                                                    threads: threads,
                                                    unsafeCoder: unsafeCoder,
                                                    filtered: true,
                                                    useGPU: useGPU)
  }

  public static func decompress(_ compressed: Data,
                                unsafeCoder: Bool = false) throws -> Data {
    return try BEN_NBCMB.coreDecompress(compressed, unsafeCoder: unsafeCoder,
                                        filtered: true)
  }

  public static func decompressParallel(_ compressed: Data,
                                        threads: Int = 0,
                                        unsafeCoder: Bool = false) async throws -> Data {
    return try await BEN_NBCMB.coreDecompressParallel(compressed, threads: threads,
                                                      unsafeCoder: unsafeCoder,
                                                      filtered: true)
  }

  // ───────────────────────────────────────────────────────────────────────────
  // MARK: Ein Block — Wettbewerb der Filter-Varianten
  // ───────────────────────────────────────────────────────────────────────────

  /// Komprimiert einen Block mit allen Kandidaten-Varianten und behält die
  /// kleinste Ausgabe. Deterministisch: feste Kandidatenreihenfolge,
  /// strikt-kleiner-Vergleich — parallel und sequenziell bitidentisch.
  static func compressBlock(_ input: Data, unsafeCoder: Bool = false,
                            useGPU: Bool = false) throws -> Data {
    let bytes = [UInt8](input)

    // Kandidaten: Basis (kein Filter) und reine Planarisierung immer;
    // Delta-Varianten nur mit dem per Entropie vorausgewählten Stride.
    var candidates: [(stride: Int, planar: Bool)] = [(0, false), (0, true)]
    let strideCandidate = NibblePlanarDeltaFilter.chooseStride(
                            bytes, unsafeVariant: unsafeCoder)
    if strideCandidate > 0 {
      candidates.append((strideCandidate, false))
      candidates.append((strideCandidate, true))
    }

    var deltaCache: [UInt8]? = nil   // Delta-Bytes nur einmal berechnen
    var best: Data? = nil
    for candidate in candidates {
      let payload: [UInt8]
      if candidate.stride == 0 {
        payload = bytes
      } else {
        if deltaCache == nil {
          var d = bytes
          NibblePlanarDeltaFilter.deltaEncode(&d, stride: candidate.stride,
                                              unsafeVariant: unsafeCoder)
          deltaCache = d
        }
        payload = deltaCache!
      }

      var nibs = nibbles(from: payload, unsafeVariant: unsafeCoder)
      if candidate.planar {
        nibs = NibblePlanarDeltaFilter.planarize(nibs, unsafeVariant: unsafeCoder)
      }
      let body = try BEN_NBCM.compressNibbles(nibs, unsafeCoder: unsafeCoder,
                                              useGPU: useGPU)

      var variantOut = Data(capacity: 1 + body.count)
      variantOut.append(NibblePlanarDeltaFilter.makeInfoByte(
                          stride: candidate.stride, planar: candidate.planar))
      variantOut.append(body)

      if best == nil || variantOut.count < best!.count {
        best = variantOut
      }
    }

    guard let result = best else {
      throw BEN_NBCMBFError.invalidData("Interner Fehler: keine Variante erzeugt")
    }
    return result
  }

  /// Dekomprimiert einen Block: Filter-Byte lesen, BEN_NBCM-Payload
  /// dekodieren, dann Deplanarisierung und Delta-Umkehr in umgekehrter
  /// Reihenfolge der Kompression anwenden.
  static func decompressBlock(_ compressed: Data, unsafeCoder: Bool = false) throws -> Data {
    let raw = Array(compressed)
    guard raw.count >= 1 else {
      throw BEN_NBCMBFError.invalidData("Filter-Byte fehlt")
    }
    guard let filter = NibblePlanarDeltaFilter.parseInfoByte(raw[0]) else {
      throw BEN_NBCMBFError.invalidData(
        "Ungültiges Filter-Byte 0x\(String(raw[0], radix: 16, uppercase: true))")
    }

    var nibs = try BEN_NBCM.decompressToNibbles(raw, startPos: 1,
                                                unsafeCoder: unsafeCoder)
    if filter.planar {
      nibs = NibblePlanarDeltaFilter.deplanarize(nibs, unsafeVariant: unsafeCoder)
    }
    var payloadBytes = bytes(from: nibs, unsafeVariant: unsafeCoder)
    if filter.stride > 0 {
      NibblePlanarDeltaFilter.deltaDecode(&payloadBytes, stride: filter.stride,
                                          unsafeVariant: unsafeCoder)
    }
    return Data(payloadBytes)
  }

  // ───────────────────────────────────────────────────────────────────────────
  // MARK: Byte-/Nibble-Konvertierung (safe + unsafe)
  // ───────────────────────────────────────────────────────────────────────────

  private static func nibbles(from bytes: [UInt8],
                              unsafeVariant: Bool) -> [UInt8] {
    let n = bytes.count
    var out = [UInt8](repeating: 0, count: n * 2)
    if unsafeVariant {
      bytes.withUnsafeBufferPointer { src in
        out.withUnsafeMutableBufferPointer { dst in
          var i = 0
          while i < n {
            dst[2 * i]     = src[i] >> 4
            dst[2 * i + 1] = src[i] & 0x0F
            i += 1
          }
        }
      }
    } else {
      var i = 0
      while i < n {
        out[2 * i]     = bytes[i] >> 4
        out[2 * i + 1] = bytes[i] & 0x0F
        i += 1
      }
    }
    return out
  }

  private static func bytes(from nibbles: [UInt8],
                            unsafeVariant: Bool) -> [UInt8] {
    let n = nibbles.count / 2
    var out = [UInt8](repeating: 0, count: n)
    if unsafeVariant {
      nibbles.withUnsafeBufferPointer { src in
        out.withUnsafeMutableBufferPointer { dst in
          var i = 0
          while i < n {
            dst[i] = (src[2 * i] << 4) | src[2 * i + 1]
            i += 1
          }
        }
      }
    } else {
      var i = 0
      while i < n {
        out[i] = (nibbles[2 * i] << 4) | nibbles[2 * i + 1]
        i += 1
      }
    }
    return out
  }

  // ───────────────────────────────────────────────────────────────────────────
  // MARK: Self-Test
  // ───────────────────────────────────────────────────────────────────────────

  @discardableResult
  public static func selfTest() -> Bool {
    var failures = [String]()

    // Deterministischer Zufall (LCG) — Self-Test muss reproduzierbar sein.
    var lcgState: UInt64 = 0x42
    func lcg() -> UInt8 {
      lcgState = lcgState &* 6364136223846793005 &+ 1442695040888963407
      return UInt8(truncatingIfNeeded: lcgState >> 56)
    }
    func lcg16() -> Int { Int(lcg()) << 8 | Int(lcg()) }

    func roundtrip(_ label: String, _ orig: Data, blockSize: Int) {
      do {
        let c = try compress(orig, blockSize: blockSize)
        let d = try decompress(c)
        if orig != d { failures.append("'\(label)' (bs=\(blockSize)): Mismatch") }
      } catch {
        failures.append("'\(label)' (bs=\(blockSize)): \(error)")
      }
    }

    // 1. Grenzfälle und Blockgrenzen-Stress (wie BEN_NBCMB)
    let text = Data(String(repeating: "the quick brown fox jumps over the lazy dog ",
                           count: 400).utf8)   // 17600 B
    for bs in [1024, 4096, 17600, 17601, 1 << 20] {
      roundtrip("Text", text, blockSize: bs)
    }
    roundtrip("leer", Data(), blockSize: 1024)
    roundtrip("1 Byte", Data([0xAB]), blockSize: 1024)
    roundtrip("exakt 1 Block", Data(repeating: 0x42, count: 1024), blockSize: 1024)
    roundtrip("1 Block + 1", Data(repeating: 0x42, count: 1025), blockSize: 1024)
    for r in 0..<10 {
      let orig = Data((0..<4096).map { _ in lcg() })
      roundtrip("Zufall \(r)", orig, blockSize: 1000)
    }

    // 2. Zielfall: 32-Bit-Werte, High-Bytes strukturiert (langsamer Zähler),
    //    Low-Bytes verrauscht — hier MUSS der Filter greifen und gewinnen.
    var structNoise = Data()
    var counter = 1000
    for _ in 0..<4000 {
      counter += Int(lcg() & 0x03)
      let noise = lcg16()
      let value = UInt32((counter & 0xFFFF) << 16 | noise)
      structNoise.append(UInt8(value & 0xFF))            // Little Endian
      structNoise.append(UInt8((value >> 8) & 0xFF))
      structNoise.append(UInt8((value >> 16) & 0xFF))
      structNoise.append(UInt8((value >> 24) & 0xFF))
    }
    roundtrip("Struktur+Rauschen", structNoise, blockSize: 1 << 20)
    do {
      let filtered   = try compress(structNoise, blockSize: 1 << 20)
      let unfiltered = try BEN_NBCMB.compress(structNoise, blockSize: 1 << 20)
      if filtered.count >= unfiltered.count {
        failures.append("Zielfall: Filter gewinnt nicht "
                        + "(\(filtered.count) ≥ \(unfiltered.count))")
      }
      // Filter-Byte des ersten Blocks: [4B bs][4B count][4B len] → Offset 12
      if filtered.count > 12 && filtered[12] == 0x00 {
        failures.append("Zielfall: Filter-Byte 0x00 — Filter greift nicht")
      }
    } catch {
      failures.append("Zielfall: \(error)")
    }

    // 3. Nie-schlechter-Garantie: höchstens 1 Byte je Block Overhead.
    do {
      let filtered   = try compress(text, blockSize: 4096)
      let unfiltered = try BEN_NBCMB.compress(text, blockSize: 4096)
      let blockCount = (text.count + 4095) / 4096
      if filtered.count > unfiltered.count + blockCount {
        failures.append("Nie-schlechter verletzt: "
                        + "\(filtered.count) > \(unfiltered.count) + \(blockCount)")
      }
    } catch {
      failures.append("Nie-schlechter: \(error)")
    }

    // 4. Safe/Unsafe bitidentisch inkl. Kreuz-Dekodierung.
    do {
      let safeOut   = try compress(structNoise, blockSize: 65536, unsafeCoder: false)
      let unsafeOut = try compress(structNoise, blockSize: 65536, unsafeCoder: true)
      if safeOut != unsafeOut {
        failures.append("safe/unsafe nicht bitidentisch")
      }
      let crossDecoded = try decompress(safeOut, unsafeCoder: true)
      if crossDecoded != structNoise {
        failures.append("Kreuz-Dekodierung (safe→unsafe) fehlgeschlagen")
      }
    } catch {
      failures.append("safe/unsafe: \(error)")
    }

    if failures.isEmpty {
      print("✅ BEN_NBCMBF Self-Test bestanden")
      print("   Roundtrips, Zielfall-Gewinn, Nie-schlechter-Garantie,")
      print("   safe/unsafe bitidentisch: verifiziert ✓")
    } else {
      print("❌ BEN_NBCMBF FEHLGESCHLAGEN (\(failures.count) Fehler):")
      failures.prefix(8).forEach { print("   \($0)") }
    }
    return failures.isEmpty
  }
}
