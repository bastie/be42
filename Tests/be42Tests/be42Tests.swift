// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Sebastian Ritter <bastie@users.noreply.github.com>

import Testing
import Foundation
@testable import be42

/// Deterministischer Zufallsgenerator (LCG) — reproduzierbare Tests.
private struct SeededRandom {
  var state: UInt64
  mutating func nextByte() -> UInt8 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return UInt8((state >> 56) & 0xFF)
  }
  mutating func data(count: Int) -> Data {
    Data((0..<count).map { _ in nextByte() })
  }
}

private let edgeCases: [Data] = [
  Data(),
  Data([0x00]),
  Data([0xFF]),
  Data([0xAA]),
  Data([0xAB, 0xCD]),
  Data([0x12, 0x34, 0x12]),
  Data(0x00...0xFF),
  Data(repeating: 0x00, count: 1000),
  Data(repeating: 0xFF, count: 1000),
  Data(repeating: 0xAB, count: 4096),
  Data([UInt8]((0..<4096).map { $0 % 2 == 0 ? 0x20 : 0x02 })),
  Data(String(repeating: "the quick brown fox ", count: 300).utf8),
]

// MARK: - BEN_MEC

@Suite struct BEN_MECTests {

  @Test func roundtripEdgeCases() throws {
    for orig in edgeCases {
      let compressed = try BEN_MEC.compress(orig)
      let restored   = try BEN_MEC.decompress(compressed)
      #expect(restored == orig, "Roundtrip-Mismatch bei \(orig.count) Bytes")
    }
  }

  @Test func roundtripSingleByteSweep() throws {
    for byte in 0...255 as ClosedRange<UInt8> {
      let orig = Data([byte])
      #expect(try BEN_MEC.decompress(BEN_MEC.compress(orig)) == orig,
              "Mismatch bei Byte 0x\(String(byte, radix: 16))")
    }
  }

  @Test func roundtripRandom() throws {
    var rng = SeededRandom(state: 0xBE42_BE42_BE42_BE42)
    for round in 0..<20 {
      let orig = rng.data(count: 2048)
      #expect(try BEN_MEC.decompress(BEN_MEC.compress(orig)) == orig,
              "Mismatch in Zufallsrunde \(round)")
    }
  }

  @Test func compressesStructuredData() throws {
    let text = Data(String(repeating: "Hello Nibble World! Wir komprimieren anders. ",
                           count: 300).utf8)
    let compressed = try BEN_MEC.compress(text)
    #expect(compressed.count * 2 < text.count,
            "Strukturierter Text muss unter 50 % fallen (\(compressed.count)/\(text.count))")
  }

  @Test func randomDataExpandsOnlyMarginally() throws {
    var rng = SeededRandom(state: 0x1337_CAFE_DEAD_BEEF)
    let orig = rng.data(count: 20_000)
    let compressed = try BEN_MEC.compress(orig)
    #expect(compressed.count < orig.count + orig.count / 16,
            "Zufallsdaten dürfen maximal ~6 % wachsen")
  }

  @Test func rejectsCorruptHeader() {
    #expect(throws: (any Error).self) {
      _ = try BEN_MEC.decompress(Data([0x00, 0x01]))            // zu kurz
    }
    #expect(throws: (any Error).self) {
      _ = try BEN_MEC.decompress(Data([0, 0, 0, 3,  0, 0, 0, 0])) // ungerade Anzahl
    }
    #expect(throws: (any Error).self) {
      _ = try BEN_MEC.decompress(Data([0, 0, 0, 4,  0, 0, 0, 9])) // Index ≥ Anzahl
    }
  }
}

// MARK: - BEN_CM

@Suite struct BEN_CMTests {

  @Test func roundtripEdgeCases() throws {
    for orig in edgeCases {
      let compressed = try BEN_CM.compress(orig)
      let restored   = try BEN_CM.decompress(compressed)
      #expect(restored == orig, "Roundtrip-Mismatch bei \(orig.count) Bytes")
    }
  }

  @Test func roundtripSingleByteSweep() throws {
    for byte in 0...255 as ClosedRange<UInt8> {
      let orig = Data([byte])
      #expect(try BEN_CM.decompress(BEN_CM.compress(orig)) == orig,
              "Mismatch bei Byte 0x\(String(byte, radix: 16))")
    }
  }

  @Test func roundtripRandom() throws {
    var rng = SeededRandom(state: 0xC0FF_EE00_BE42_0043)
    for round in 0..<10 {
      let orig = rng.data(count: 2048)
      #expect(try BEN_CM.decompress(BEN_CM.compress(orig)) == orig,
              "Mismatch in Zufallsrunde \(round)")
    }
  }

  @Test func compressesStructuredData() throws {
    let text = Data(String(repeating: "Hello Nibble World! Wir komprimieren anders. ",
                           count: 300).utf8)
    let compressed = try BEN_CM.compress(text)
    #expect(compressed.count * 4 < text.count,
            "Strukturierter Text muss unter 25 % fallen (\(compressed.count)/\(text.count))")
  }

  @Test func randomDataExpandsOnlyMarginally() throws {
    var rng = SeededRandom(state: 0x1337_CAFE_DEAD_BEEF)
    let orig = rng.data(count: 20_000)
    let compressed = try BEN_CM.compress(orig)
    #expect(compressed.count < orig.count + orig.count / 16,
            "Zufallsdaten dürfen maximal ~6 % wachsen")
  }

  @Test func rejectsCorruptHeader() {
    #expect(throws: (any Error).self) {
      _ = try BEN_CM.decompress(Data([0x00, 0x01]))   // zu kurz
    }
  }
}

// MARK: - BEN_NBCM

@Suite struct BEN_NBCMTests {

  @Test func roundtripEdgeCases() throws {
    for orig in edgeCases {
      let compressed = try BEN_NBCM.compress(orig)
      let restored   = try BEN_NBCM.decompress(compressed)
      #expect(restored == orig, "Roundtrip-Mismatch bei \(orig.count) Bytes")
    }
  }

  @Test func roundtripSingleByteSweep() throws {
    for byte in 0...255 as ClosedRange<UInt8> {
      let orig = Data([byte])
      #expect(try BEN_NBCM.decompress(BEN_NBCM.compress(orig)) == orig,
              "Mismatch bei Byte 0x\(String(byte, radix: 16))")
    }
  }

  @Test func roundtripRandom() throws {
    var rng = SeededRandom(state: 0xBE42_0004_DEAD_BEEF)
    for round in 0..<15 {
      let orig = rng.data(count: 2048)
      #expect(try BEN_NBCM.decompress(BEN_NBCM.compress(orig)) == orig,
              "Mismatch in Zufallsrunde \(round)")
    }
  }

  @Test func compressesStructuredData() throws {
    let text = Data(String(repeating: "Hello Nibble World! Wir komprimieren anders. ",
                           count: 300).utf8)
    let compressed = try BEN_NBCM.compress(text)
    #expect(compressed.count * 2 < text.count,
            "Strukturierter Text muss unter 50 % fallen (\(compressed.count)/\(text.count))")
  }

  @Test func rejectsCorruptHeader() {
    #expect(throws: (any Error).self) {
      _ = try BEN_NBCM.decompress(Data([0x00, 0x01]))              // zu kurz
    }
    #expect(throws: (any Error).self) {
      _ = try BEN_NBCM.decompress(Data([0, 0, 0, 3,  0, 0, 0, 0])) // ungerade
    }
    #expect(throws: (any Error).self) {
      _ = try BEN_NBCM.decompress(Data([0, 0, 0, 4,  0, 0, 0, 9])) // Index ≥ Anzahl
    }
  }
}

// MARK: - BEN_NBCMB (Block-Modus)

@Suite struct BEN_NBCMBTests {

  @Test func roundtripEdgeCases() throws {
    for orig in edgeCases {
      let compressed = try BEN_NBCMB.compress(orig, blockSize: 1024)
      let restored   = try BEN_NBCMB.decompress(compressed)
      #expect(restored == orig, "Roundtrip-Mismatch bei \(orig.count) Bytes")
    }
  }

  @Test func roundtripAtBlockBoundaries() throws {
    // Größen exakt an und um Blockgrenzen
    for size in [1023, 1024, 1025, 2047, 2048, 2049, 4096] {
      let orig = Data((0..<size).map { UInt8($0 % 251) })
      #expect(try BEN_NBCMB.decompress(BEN_NBCMB.compress(orig, blockSize: 1024)) == orig,
              "Mismatch bei Größe \(size)")
    }
  }

  @Test func roundtripRandomMultiBlock() throws {
    var rng = SeededRandom(state: 0xBE42_0005_0000_0001)
    for round in 0..<10 {
      let orig = rng.data(count: 8192)
      #expect(try BEN_NBCMB.decompress(BEN_NBCMB.compress(orig, blockSize: 1000)) == orig,
              "Mismatch in Zufallsrunde \(round)")
    }
  }

  @Test func singleBlockMatchesNBCMRatio() throws {
    // Ein Block ⇒ Payload identisch zu BEN_NBCM plus 12 Byte Block-Header
    let text = Data(String(repeating: "the quick brown fox ", count: 300).utf8)
    let single = try BEN_NBCM.compress(text)
    let blocked = try BEN_NBCMB.compress(text)   // Default-Blockgröße > Textgröße
    #expect(blocked.count == single.count + 12)
  }

  @Test func rejectsCorruptHeader() {
    #expect(throws: (any Error).self) {
      _ = try BEN_NBCMB.decompress(Data([0x00, 0x01]))                    // zu kurz
    }
    #expect(throws: (any Error).self) {
      // blockCount 1, aber kein Block vorhanden
      _ = try BEN_NBCMB.decompress(Data([0, 0, 4, 0,  0, 0, 0, 1]))
    }
  }

  @Test func parallelMatchesSequentialBitExactly() async throws {
    var rng = SeededRandom(state: 0xBE42_5EED_0000_0001)
    // gemischte Inhalte: Text + Zufall, mehrere Blöcke, mehrere Threadzahlen
    var orig = Data(String(repeating: "block parallel bijektiv ", count: 500).utf8)
    orig.append(rng.data(count: 20_000))
    let sequential = try BEN_NBCMB.compress(orig, blockSize: 4096)
    for threads in [1, 2, 4, 0] {
      let parallel = try await BEN_NBCMB.compressParallel(orig, blockSize: 4096,
                                                          threads: threads)
      #expect(parallel == sequential,
              "Parallel (T=\(threads)) muss bitidentisch zur sequenziellen Ausgabe sein")
      let restored = try await BEN_NBCMB.decompressParallel(parallel, threads: threads)
      #expect(restored == orig)
    }
  }
}

// MARK: - BEN_BWT (Bestandsalgorithmus)

@Suite struct BEN_BWTTests {

  @Test func roundtripEdgeCases() throws {
    for orig in edgeCases {
      let compressed = try BEN_BWT.compress(orig)
      let restored   = try BEN_BWT.decompress(compressed)
      #expect(restored == orig, "Roundtrip-Mismatch bei \(orig.count) Bytes")
    }
  }

  @Test func roundtripRandom() throws {
    var rng = SeededRandom(state: 0xBE42_0000_0000_0042)
    for round in 0..<10 {
      let orig = rng.data(count: 1024)
      #expect(try BEN_BWT.decompress(BEN_BWT.compress(orig)) == orig,
              "Mismatch in Zufallsrunde \(round)")
    }
  }
}

// MARK: - Container-Format

@Suite struct ContainerTests {

  @Test func headerRoundtripBEN_BWT() throws {
    var format = be42()
    format.algorithm = .BEN_BWT
    var data = format.getHeader()
    data.append(contentsOf: [0x00])   // checkHeader verlangt > headerCount
    #expect(try format.checkHeader(in: data) == .BEN_BWT)
  }

  @Test func headerRoundtripBEN_MEC() throws {
    var format = be42()
    format.algorithm = .BEN_MEC
    var data = format.getHeader()
    data.append(contentsOf: [0x00])
    #expect(try format.checkHeader(in: data) == .BEN_MEC)
  }

  @Test func rejectsUnknownAlgorithm() {
    let format = be42()
    #expect(throws: (any Error).self) {
      _ = try format.checkHeader(in: [0xBE, 0x42, 0x01, 0x7F, 0x00])
    }
  }

  @Test func rejectsWrongMagic() {
    let format = be42()
    #expect(throws: (any Error).self) {
      _ = try format.checkHeader(in: [0xDE, 0xAD, 0x01, 0x01, 0x00])
    }
  }

  @Test func headerRoundtripBEN_CM() throws {
    var format = be42()
    format.algorithm = .BEN_CM
    var data = format.getHeader()
    data.append(contentsOf: [0x00])
    #expect(try format.checkHeader(in: data) == .BEN_CM)
  }

  @Test func headerRoundtripBEN_NBCM() throws {
    var format = be42()
    format.algorithm = .BEN_NBCM
    var data = format.getHeader()
    data.append(contentsOf: [0x00])
    #expect(try format.checkHeader(in: data) == .BEN_NBCM)
  }

  @Test func headerRoundtripBEN_NBCMB() throws {
    var format = be42()
    format.algorithm = .BEN_NBCMB
    var data = format.getHeader()
    data.append(contentsOf: [0x00])
    #expect(try format.checkHeader(in: data) == .BEN_NBCMB)
  }

  @Test func algorithmRawValues() {
    #expect(Algorithm.BEN_BWT.rawValue == "nbbmr")
    #expect(Algorithm.BEN_MEC.rawValue == "nbmec")
    #expect(Algorithm.BEN_CM.rawValue == "ncmm")
    #expect(Algorithm.BEN_NBCM.rawValue == "nbcm")
    #expect(Algorithm.BEN_NBCMB.rawValue == "nbcmb")
    #expect(Algorithm(rawValue: "nbmec") == .BEN_MEC)
    #expect(Algorithm(rawValue: "nbbmr") == .BEN_BWT)
    #expect(Algorithm(rawValue: "ncmm") == .BEN_CM)
    #expect(Algorithm(rawValue: "nbcm") == .BEN_NBCM)
    #expect(Algorithm(rawValue: "nbcmb") == .BEN_NBCMB)
    #expect(Algorithm(rawValue: "gibtsnicht") == nil)
  }
}
