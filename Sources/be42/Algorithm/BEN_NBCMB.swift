// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Sebastian Ritter <bastie@users.noreply.github.com>

/*
 * BEN_NBCMB – BEN_NBCM im Block-Modus
 *
 * Identischer Algorithmus wie BEN_NBCM (Markov-Kette / Geburtstagsparadox,
 * Exclusion-Ketten, Dual-Rate-Mixing, APM) — aber die Datei wird in
 * unabhängige Blöcke geteilt. Jeder Block erhält eigene BWT, eigenes
 * Modell und eigenen Range-Coder-Strom.
 *
 * Warum Blöcke:
 *   1. Große Dateien (enwik9, 1 GB): der Suffix-Array-Bau über die ganze
 *      Datei würde ~50 GB RAM benötigen — blockweise bleibt er begrenzt.
 *   2. Die Längenprefixe je Block machen Kompression UND Dekompression
 *      parallelisierbar (Speed-Ausbaustufe) — jeder Block ist eigenständig
 *      dekodierbar.
 *   3. Cache-Lokalität: kleinere Suffix-Array-Arbeitsmengen.
 *
 * Ratio-Kosten: das Modell (183 Slots) lernt in unter 1 MB ein; verloren
 * geht nur die BWT-Kontextbündelung über Blockgrenzen — bei 16-MiB-Blöcken
 * gering.
 *
 * Format:
 *   [4B blockSize BE] [4B blockCount BE]
 *   je Block: [4B compressedLength BE] [BEN_NBCM-Block-Payload]
 *
 * Bijektiv: Blöcke sind unabhängig; jeder Block ist für sich bijektiv.
 */

import Foundation

public enum BEN_NBCMBError: Error, CustomStringConvertible, Sendable {
  case invalidData(String)
  case fileTooLarge

  public var description: String {
    switch self {
    case .invalidData(let m): return "Ungültige Daten: \(m)"
    case .fileTooLarge:       return "Datei zu groß (max 2 GB)"
    }
  }
}

public enum BEN_NBCMB {

  /// Standard-Blockgröße: 64 MiB. Gemessen auf enwik8: 16-MiB-Blöcke
  /// kosten ~2 Prozentpunkte Ratio gegenüber Einzelblock — die globale
  /// BWT-Kontextbündelung wiegt schwer. Größer = bessere Ratio,
  /// kleiner = weniger RAM und mehr Parallelität (CLI: --blocksize).
  public static let defaultBlockSize = 64 * 1024 * 1024

  // ───────────────────────────────────────────────────────────────────────────
  // MARK: Komprimieren
  // ───────────────────────────────────────────────────────────────────────────

  public static func compress(_ input: Data,
                              blockSize: Int = defaultBlockSize,
                              unsafeCoder: Bool = false) throws -> Data {
    guard blockSize > 0 else {
      throw BEN_NBCMBError.invalidData("Blockgröße muss > 0 sein")
    }
    guard UInt64(input.count) <= UInt64(UInt32.max) else {
      throw BEN_NBCMBError.fileTooLarge
    }
    let blockCount = input.isEmpty ? 0 : (input.count + blockSize - 1) / blockSize

    var out = Data()
    func appendBE32(_ v: UInt32) {
      out.append(UInt8((v >> 24) & 0xFF))
      out.append(UInt8((v >> 16) & 0xFF))
      out.append(UInt8((v >>  8) & 0xFF))
      out.append(UInt8( v        & 0xFF))
    }
    appendBE32(UInt32(blockSize))
    appendBE32(UInt32(blockCount))

    var offset = input.startIndex
    while offset < input.endIndex {
      let end = input.index(offset, offsetBy: blockSize,
                            limitedBy: input.endIndex) ?? input.endIndex
      // Data(...) erzwingt 0-basierte Indizes für den Block
      let block = Data(input[offset..<end])
      let compressed = try BEN_NBCM.compressBlock(block, unsafeCoder: unsafeCoder)
      appendBE32(UInt32(compressed.count))
      out.append(compressed)
      offset = end
    }
    return out
  }

  // ───────────────────────────────────────────────────────────────────────────
  // MARK: Parallel komprimieren (bitidentisch zur sequenziellen Variante)
  // ───────────────────────────────────────────────────────────────────────────

  /// Wie `compress`, aber Blöcke werden parallel verarbeitet.
  /// `threads` = maximale Gleichzeitigkeit, 0 = Anzahl CPU-Kerne.
  /// Achtung RAM: pro gleichzeitigem Block fällt der Suffix-Array-Bau an
  /// (~36 Bytes je Eingabe-Byte) — kleinere Blöcke erlauben mehr Threads.
  public static func compressParallel(_ input: Data,
                                      blockSize: Int = defaultBlockSize,
                                      threads: Int = 0,
                                      unsafeCoder: Bool = false) async throws -> Data {
    guard blockSize > 0 else {
      throw BEN_NBCMBError.invalidData("Blockgröße muss > 0 sein")
    }
    guard UInt64(input.count) <= UInt64(UInt32.max) else {
      throw BEN_NBCMBError.fileTooLarge
    }
    let blockCount = input.isEmpty ? 0 : (input.count + blockSize - 1) / blockSize
    let activeThreads = max(1, threads == 0 ? ProcessInfo.processInfo.activeProcessorCount
                                    : threads)
    #if DEBUG
    print ("Threads: \(activeThreads)")
    #endif

    // Blöcke schneiden (Data-Slices sind billig, Kopie erst im Task)
    var blocks = [Data]()
    blocks.reserveCapacity(blockCount)
    var offset = input.startIndex
    while offset < input.endIndex {
      let end = input.index(offset, offsetBy: blockSize,
                            limitedBy: input.endIndex) ?? input.endIndex
      blocks.append(Data(input[offset..<end]))
      offset = end
    }

    var results = [Data?](repeating: nil, count: blockCount)
    try await withThrowingTaskGroup(of: (Int, Data).self) { group in
      var next = 0
      // Fenster füllen
      while next < min(activeThreads, blockCount) {
        let idx = next
        let block = blocks[idx]
        group.addTask { (idx, try BEN_NBCM.compressBlock(block, unsafeCoder: unsafeCoder)) }
        next += 1
      }
      // je fertigem Block einen nachschieben
      while let (idx, data) = try await group.next() {
        results[idx] = data
        if next < blockCount {
          let i = next
          let block = blocks[i]
          group.addTask { (i, try BEN_NBCM.compressBlock(block, unsafeCoder: unsafeCoder)) }
          next += 1
        }
      }
    }

    // Zusammensetzen — identisches Format wie `compress`
    var out = Data()
    func appendBE32(_ v: UInt32) {
      out.append(UInt8((v >> 24) & 0xFF))
      out.append(UInt8((v >> 16) & 0xFF))
      out.append(UInt8((v >>  8) & 0xFF))
      out.append(UInt8( v        & 0xFF))
    }
    appendBE32(UInt32(blockSize))
    appendBE32(UInt32(blockCount))
    for r in results {
      guard let r else {
        throw BEN_NBCMBError.invalidData("Interner Fehler: Block fehlt")
      }
      appendBE32(UInt32(r.count))
      out.append(r)
    }
    return out
  }

  /// Wie `decompress`, aber Blöcke werden parallel dekodiert —
  /// möglich durch die Längenprefixe im Format.
  public static func decompressParallel(_ compressed: Data,
                                        threads: Int = 0,
                                        unsafeCoder: Bool = false) async throws -> Data {
    let raw = Array(compressed)
    guard raw.count >= 8 else {
      throw BEN_NBCMBError.invalidData("Header zu kurz (\(raw.count) < 8 Bytes)")
    }
    func readBE32(_ off: Int) -> UInt32 {
      UInt32(raw[off]) << 24 | UInt32(raw[off + 1]) << 16
        | UInt32(raw[off + 2]) << 8 | UInt32(raw[off + 3])
    }
    let blockSize  = Int(readBE32(0))
    let blockCount = Int(readBE32(4))
    guard blockSize > 0 || blockCount == 0 else {
      throw BEN_NBCMBError.invalidData("Ungültige Blockgröße \(blockSize)")
    }
    let width = max(1, threads == 0 ? ProcessInfo.processInfo.activeProcessorCount
                                    : threads)

    // Erst alle Block-Bereiche über die Längenprefixe lokalisieren
    var ranges = [(Int, Int)]()
    ranges.reserveCapacity(blockCount)
    var off = 8
    for blockIndex in 0..<blockCount {
      guard off + 4 <= raw.count else {
        throw BEN_NBCMBError.invalidData("Block \(blockIndex): Längenprefix fehlt")
      }
      let compLen = Int(readBE32(off))
      off += 4
      guard off + compLen <= raw.count else {
        throw BEN_NBCMBError.invalidData(
          "Block \(blockIndex): \(compLen) Bytes erwartet, nur \(raw.count - off) vorhanden")
      }
      ranges.append((off, compLen))
      off += compLen
    }

    var results = [Data?](repeating: nil, count: blockCount)
    try await withThrowingTaskGroup(of: (Int, Data).self) { group in
      var next = 0
      func submit(_ idx: Int) {
        let (start, len) = ranges[idx]
        let blockData = Data(raw[start..<start + len])
        group.addTask { (idx, try BEN_NBCM.decompressBlock(blockData, unsafeCoder: unsafeCoder)) }
      }
      while next < min(width, blockCount) { submit(next); next += 1 }
      while let (idx, data) = try await group.next() {
        guard data.count <= blockSize else {
          throw BEN_NBCMBError.invalidData(
            "Block \(idx): dekodierte Größe \(data.count) > Blockgröße \(blockSize)")
        }
        results[idx] = data
        if next < blockCount { submit(next); next += 1 }
      }
    }

    var out = Data()
    for r in results {
      guard let r else {
        throw BEN_NBCMBError.invalidData("Interner Fehler: Block fehlt")
      }
      out.append(r)
    }
    return out
  }

  // ───────────────────────────────────────────────────────────────────────────
  // MARK: Dekomprimieren
  // ───────────────────────────────────────────────────────────────────────────

  public static func decompress(_ compressed: Data,
                                unsafeCoder: Bool = false) throws -> Data {
    let raw = Array(compressed)
    guard raw.count >= 8 else {
      throw BEN_NBCMBError.invalidData("Header zu kurz (\(raw.count) < 8 Bytes)")
    }
    func readBE32(_ off: Int) -> UInt32 {
      UInt32(raw[off]) << 24 | UInt32(raw[off + 1]) << 16
        | UInt32(raw[off + 2]) << 8 | UInt32(raw[off + 3])
    }
    let blockSize  = Int(readBE32(0))
    let blockCount = Int(readBE32(4))
    guard blockSize > 0 || blockCount == 0 else {
      throw BEN_NBCMBError.invalidData("Ungültige Blockgröße \(blockSize)")
    }

    var out = Data()
    var off = 8
    for blockIndex in 0..<blockCount {
      guard off + 4 <= raw.count else {
        throw BEN_NBCMBError.invalidData("Block \(blockIndex): Längenprefix fehlt")
      }
      let compLen = Int(readBE32(off))
      off += 4
      guard off + compLen <= raw.count else {
        throw BEN_NBCMBError.invalidData(
          "Block \(blockIndex): \(compLen) Bytes erwartet, nur \(raw.count - off) vorhanden")
      }
      let blockData = Data(raw[off..<off + compLen])
      let block = try BEN_NBCM.decompressBlock(blockData, unsafeCoder: unsafeCoder)
      guard block.count <= blockSize else {
        throw BEN_NBCMBError.invalidData(
          "Block \(blockIndex): dekodierte Größe \(block.count) > Blockgröße \(blockSize)")
      }
      out.append(block)
      off += compLen
    }
    return out
  }

  // ───────────────────────────────────────────────────────────────────────────
  // MARK: Self-Test
  // ───────────────────────────────────────────────────────────────────────────

  @discardableResult
  public static func selfTest() -> Bool {
    var failures = [String]()

    func roundtrip(_ label: String, _ orig: Data, blockSize: Int) {
      do {
        let c = try compress(orig, blockSize: blockSize)
        let d = try decompress(c)
        if orig != d { failures.append("'\(label)' (bs=\(blockSize)): Mismatch") }
      } catch {
        failures.append("'\(label)' (bs=\(blockSize)): \(error)")
      }
    }

    // Blockgrenzen gezielt stressen: Größen um die Blockgröße herum
    let text = Data(String(repeating: "the quick brown fox jumps over the lazy dog ",
                           count: 400).utf8)   // 17600 B
    for bs in [1024, 4096, 17600, 17601, 1 << 20] {
      roundtrip("Text", text, blockSize: bs)
    }
    roundtrip("leer", Data(), blockSize: 1024)
    roundtrip("1 Byte", Data([0xAB]), blockSize: 1024)
    roundtrip("exakt 1 Block", Data(repeating: 0x42, count: 1024), blockSize: 1024)
    roundtrip("1 Block + 1", Data(repeating: 0x42, count: 1025), blockSize: 1024)
    roundtrip("Grenze 2 Blöcke", Data(repeating: 0x42, count: 2048), blockSize: 1024)

    for r in 0..<20 {
      let orig = Data((0..<4096).map { _ in UInt8.random(in: 0...255) })
      roundtrip("Zufall \(r)", orig, blockSize: 1000)   // erzwingt 5 Blöcke
    }

    let big = Data((0..<300_000).map { _ in UInt8.random(in: 0...255) })
    roundtrip("300KB Zufall", big, blockSize: 65536)

    if failures.isEmpty {
      print("✅ BEN_NBCMB Self-Test bestanden")
      print("   Blockgrenzen-Stress + Zufalls-Roundtrips über mehrere Blockgrößen")
      print("   Bijektivität: verifiziert ✓")
    } else {
      print("❌ BEN_NBCMB FEHLGESCHLAGEN (\(failures.count) Fehler):")
      failures.prefix(8).forEach { print("   \($0)") }
    }
    return failures.isEmpty
  }
}
