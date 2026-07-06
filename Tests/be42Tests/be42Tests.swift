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

  @Test func unsafeCoderMatchesSafeBitExactly() async throws {
    var rng = SeededRandom(state: 0xBE42_00A5_AFEC_0DE5)
    var orig = Data(String(repeating: "safe und unsafe muessen identisch sein ", count: 400).utf8)
    orig.append(rng.data(count: 30_000))
    let safe = try BEN_NBCMB.compress(orig, blockSize: 8192)
    let fast = try BEN_NBCMB.compress(orig, blockSize: 8192, unsafeCoder: true)
    #expect(fast == safe, "unsafe-Coder muss bitidentische Ausgabe liefern")
    // kreuzweise: unsafe-Strom mit safe dekodieren und umgekehrt
    #expect(try BEN_NBCMB.decompress(fast) == orig)
    #expect(try BEN_NBCMB.decompress(safe, unsafeCoder: true) == orig)
    let par = try await BEN_NBCMB.compressParallel(orig, blockSize: 8192,
                                                   threads: 4, unsafeCoder: true)
    #expect(par == safe)
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

// MARK: - NibblePlanarDeltaFilter (Primitive)

@Suite struct NibblePlanarDeltaFilterTests {

  @Test func deltaRoundtripAllStrides() {
    var rng = SeededRandom(state: 0xBE42_F117_E200_0001)
    let orig = [UInt8]((0..<5000).map { _ in rng.nextByte() })
    for stride in NibblePlanarDeltaFilter.validStrides {
      for unsafeVariant in [false, true] {
        var work = orig
        NibblePlanarDeltaFilter.deltaEncode(&work, stride: stride,
                                            unsafeVariant: unsafeVariant)
        #expect(work != orig, "Delta (s=\(stride)) muss Daten verändern")
        NibblePlanarDeltaFilter.deltaDecode(&work, stride: stride,
                                            unsafeVariant: unsafeVariant)
        #expect(work == orig, "Delta-Roundtrip (s=\(stride), unsafe=\(unsafeVariant))")
      }
    }
  }

  @Test func deltaSafeUnsafeIdentical() {
    var rng = SeededRandom(state: 0xBE42_F117_E200_0002)
    let orig = [UInt8]((0..<3000).map { _ in rng.nextByte() })
    for stride in NibblePlanarDeltaFilter.validStrides {
      var safe = orig
      var fast = orig
      NibblePlanarDeltaFilter.deltaEncode(&safe, stride: stride, unsafeVariant: false)
      NibblePlanarDeltaFilter.deltaEncode(&fast, stride: stride, unsafeVariant: true)
      #expect(safe == fast, "safe/unsafe Delta identisch (s=\(stride))")
    }
  }

  @Test func planarizeRoundtrip() {
    var rng = SeededRandom(state: 0xBE42_F117_E200_0003)
    for count in [0, 2, 4, 6, 1000, 4096] {
      let nibs = [UInt8]((0..<count).map { _ in rng.nextByte() & 0x0F })
      for unsafeVariant in [false, true] {
        let planar = NibblePlanarDeltaFilter.planarize(nibs, unsafeVariant: unsafeVariant)
        let back   = NibblePlanarDeltaFilter.deplanarize(planar, unsafeVariant: unsafeVariant)
        #expect(back == nibs, "Planarisierung-Roundtrip (n=\(count), unsafe=\(unsafeVariant))")
      }
    }
  }

  @Test func planarizeSeparatesHighAndLow() {
    // [h0,l0,h1,l1] → [h0,h1,l0,l1]
    let nibs: [UInt8] = [0x1, 0xA, 0x2, 0xB, 0x3, 0xC]
    let planar = NibblePlanarDeltaFilter.planarize(nibs)
    #expect(planar == [0x1, 0x2, 0x3, 0xA, 0xB, 0xC])
  }

  @Test func infoByteRoundtrip() {
    for stride in [0] + NibblePlanarDeltaFilter.validStrides {
      for planar in [false, true] {
        let b = NibblePlanarDeltaFilter.makeInfoByte(stride: stride, planar: planar)
        let parsed = NibblePlanarDeltaFilter.parseInfoByte(b)
        #expect(parsed?.stride == stride)
        #expect(parsed?.planar == planar)
      }
    }
  }

  @Test func infoByteRejectsInvalid() {
    #expect(NibblePlanarDeltaFilter.parseInfoByte(0x03) == nil)  // Stride 3
    #expect(NibblePlanarDeltaFilter.parseInfoByte(0x05) == nil)  // Stride 5
    #expect(NibblePlanarDeltaFilter.parseInfoByte(0x40) == nil)  // unbekanntes Flag
    #expect(NibblePlanarDeltaFilter.parseInfoByte(0x7F) == nil)  // beides
  }

  @Test func chooseStrideFindsStructuredStride() {
    // 32-Bit-Werte, High-Bytes langsam wachsend, Low-Bytes Rauschen → Stride 4
    var rng = SeededRandom(state: 0xBE42_F117_E200_0004)
    var data = [UInt8]()
    var counter = 1000
    for _ in 0..<2000 {
      counter += Int(rng.nextByte() & 0x03)
      let noise = Int(rng.nextByte()) << 8 | Int(rng.nextByte())
      let value = UInt32((counter & 0xFFFF) << 16 | noise)
      data.append(UInt8(value & 0xFF))
      data.append(UInt8((value >> 8) & 0xFF))
      data.append(UInt8((value >> 16) & 0xFF))
      data.append(UInt8((value >> 24) & 0xFF))
    }
    #expect(NibblePlanarDeltaFilter.chooseStride(data) == 4)
    // Text hat keine numerische Struktur → kein Delta
    let text = [UInt8](String(repeating: "the quick brown fox ", count: 200).utf8)
    #expect(NibblePlanarDeltaFilter.chooseStride(text) == 0)
    // safe/unsafe identische Wahl
    #expect(NibblePlanarDeltaFilter.chooseStride(data, unsafeVariant: true) == 4)
  }
}

// MARK: - BEN_NBCMBF (Block-Modus mit Filter-Wettbewerb)

@Suite struct BEN_NBCMBFTests {

  /// Zielfall des Filters: 32-Bit-Werte, strukturierte High-, verrauschte
  /// Low-Bytes — deterministisch erzeugt.
  private func structNoiseCorpus(count: Int = 4000) -> Data {
    var rng = SeededRandom(state: 0xBE42_0006_57A7_0001)
    var data = Data()
    var counter = 1000
    for _ in 0..<count {
      counter += Int(rng.nextByte() & 0x03)
      let noise = Int(rng.nextByte()) << 8 | Int(rng.nextByte())
      let value = UInt32((counter & 0xFFFF) << 16 | noise)
      data.append(UInt8(value & 0xFF))
      data.append(UInt8((value >> 8) & 0xFF))
      data.append(UInt8((value >> 16) & 0xFF))
      data.append(UInt8((value >> 24) & 0xFF))
    }
    return data
  }

  @Test func roundtripEdgeCases() throws {
    for orig in edgeCases {
      let compressed = try BEN_NBCMBF.compress(orig, blockSize: 1024)
      let restored   = try BEN_NBCMBF.decompress(compressed)
      #expect(restored == orig, "Roundtrip-Mismatch bei \(orig.count) Bytes")
    }
  }

  @Test func roundtripAtBlockBoundaries() throws {
    for size in [1023, 1024, 1025, 2047, 2048, 2049, 4096] {
      let orig = Data((0..<size).map { UInt8($0 % 251) })
      #expect(try BEN_NBCMBF.decompress(BEN_NBCMBF.compress(orig, blockSize: 1024)) == orig,
              "Mismatch bei Größe \(size)")
    }
  }

  @Test func roundtripRandomMultiBlock() throws {
    var rng = SeededRandom(state: 0xBE42_0006_0000_0001)
    for round in 0..<10 {
      let orig = rng.data(count: 8192)
      #expect(try BEN_NBCMBF.decompress(BEN_NBCMBF.compress(orig, blockSize: 1000)) == orig,
              "Mismatch in Zufallsrunde \(round)")
    }
  }

  @Test func structNoiseRoundtripAndFilterEngages() throws {
    let orig = structNoiseCorpus()
    let compressed = try BEN_NBCMBF.compress(orig)   // ein Block (Default-Größe)
    #expect(try BEN_NBCMBF.decompress(compressed) == orig)
    // Filter-Byte des ersten Blocks: [4B bs][4B count][4B len] → Offset 12
    #expect(compressed.count > 12 && compressed[12] != 0x00,
            "Auf dem Zielfall muss eine Filter-Variante gewinnen")
  }

  @Test func structNoiseBeatsUnfiltered() throws {
    let orig = structNoiseCorpus()
    let filtered   = try BEN_NBCMBF.compress(orig)
    let unfiltered = try BEN_NBCMB.compress(orig)
    #expect(filtered.count < unfiltered.count,
            "Zielfall: Filter muss gewinnen (\(filtered.count) vs \(unfiltered.count))")
  }

  @Test func neverWorseThanUnfiltered() throws {
    // Per Konstruktion: höchstens 1 Byte je Block Overhead (Filter-Byte),
    // da die ungefilterte Variante immer Wettbewerbskandidat ist.
    for orig in edgeCases {
      let filtered   = try BEN_NBCMBF.compress(orig, blockSize: 1024)
      let unfiltered = try BEN_NBCMB.compress(orig, blockSize: 1024)
      let blockCount = orig.isEmpty ? 0 : (orig.count + 1023) / 1024
      let msg = "Nie-schlechter verletzt bei \(orig.count) Bytes: "
        + "\(filtered.count) > \(unfiltered.count) + \(blockCount)"
      #expect(filtered.count <= unfiltered.count + blockCount, "\(msg)")
    }
  }

  @Test func unsafeCoderMatchesSafeBitExactly() async throws {
    var orig = structNoiseCorpus(count: 2000)
    orig.append(Data(String(repeating: "gemischter Inhalt ", count: 300).utf8))
    let safe = try BEN_NBCMBF.compress(orig, blockSize: 8192)
    let fast = try BEN_NBCMBF.compress(orig, blockSize: 8192, unsafeCoder: true)
    #expect(fast == safe, "unsafe-Coder muss bitidentische Ausgabe liefern")
    #expect(try BEN_NBCMBF.decompress(fast) == orig)
    #expect(try BEN_NBCMBF.decompress(safe, unsafeCoder: true) == orig)
    let par = try await BEN_NBCMBF.compressParallel(orig, blockSize: 8192,
                                                    threads: 4, unsafeCoder: true)
    #expect(par == safe)
  }

  @Test func parallelMatchesSequentialBitExactly() async throws {
    var rng = SeededRandom(state: 0xBE42_0006_5EED_0001)
    var orig = structNoiseCorpus(count: 3000)
    orig.append(Data(String(repeating: "block parallel bijektiv ", count: 400).utf8))
    orig.append(rng.data(count: 10_000))
    let sequential = try BEN_NBCMBF.compress(orig, blockSize: 4096)
    for threads in [1, 2, 4, 0] {
      let parallel = try await BEN_NBCMBF.compressParallel(orig, blockSize: 4096,
                                                           threads: threads)
      #expect(parallel == sequential,
              "Parallel (T=\(threads)) muss bitidentisch zur sequenziellen Ausgabe sein")
      let restored = try await BEN_NBCMBF.decompressParallel(parallel, threads: threads)
      #expect(restored == orig)
    }
  }

  @Test func rejectsCorruptFilterByte() throws {
    let orig = Data(String(repeating: "korrupt ", count: 100).utf8)
    var compressed = try BEN_NBCMBF.compress(orig, blockSize: 1 << 20)
    // Filter-Byte des ersten Blocks (Offset 12) auf ungültigen Wert setzen
    compressed[12] = 0x7F
    #expect(throws: (any Error).self) {
      _ = try BEN_NBCMBF.decompress(compressed)
    }
  }

  @Test func rejectsCorruptHeader() {
    #expect(throws: (any Error).self) {
      _ = try BEN_NBCMBF.decompress(Data([0x00, 0x01]))
    }
    #expect(throws: (any Error).self) {
      _ = try BEN_NBCMBF.decompress(Data([0, 0, 4, 0,  0, 0, 0, 1]))
    }
  }
}

// MARK: - BEN_CME (ncmm erweitert: Alignment + Order-8/12, Nr. 59)

@Suite struct BEN_CMETests {

  /// Zielfall des Alignment-Modells: 32-Bit-Werte, strukturierte High-,
  /// verrauschte Low-Bytes — deterministisch erzeugt.
  private func structNoiseCorpus(count: Int = 4000) -> Data {
    var rng = SeededRandom(state: 0xBE42_0007_57A7_0001)
    var data = Data()
    var counter = 1000
    for _ in 0..<count {
      counter += Int(rng.nextByte() & 0x03)
      let noise = Int(rng.nextByte()) << 8 | Int(rng.nextByte())
      let value = UInt32((counter & 0xFFFF) << 16 | noise)
      data.append(UInt8(value & 0xFF))
      data.append(UInt8((value >> 8) & 0xFF))
      data.append(UInt8((value >> 16) & 0xFF))
      data.append(UInt8((value >> 24) & 0xFF))
    }
    return data
  }

  @Test func roundtripEdgeCases() throws {
    // Bewusst kompakte Auswahl: jede Instanz allokiert ~600 MB Tabellen.
    let cases: [Data] = [
      Data(),
      Data([0x00]),
      Data([0xFF]),
      Data([0xAB, 0xCD]),
      Data(0x00...0xFF),
      Data(repeating: 0xAB, count: 2048),
      Data(String(repeating: "the quick brown fox ", count: 200).utf8),
    ]
    for orig in cases {
      let compressed = try BEN_CME.compress(orig)
      let restored   = try BEN_CME.decompress(compressed)
      #expect(restored == orig, "Roundtrip-Mismatch bei \(orig.count) Bytes")
    }
  }

  @Test func roundtripRandom() throws {
    var rng = SeededRandom(state: 0xBE42_0007_DEAD_BEEF)
    for round in 0..<3 {
      let orig = rng.data(count: 2048)
      #expect(try BEN_CME.decompress(BEN_CME.compress(orig)) == orig,
              "Mismatch in Zufallsrunde \(round)")
    }
  }

  @Test func structNoiseRoundtripAndBeatsNCMM() throws {
    // Alignment-Zielfall: CME muss ncmm (BEN_CM) deutlich schlagen
    // (Python-Referenz: −8,3 %) UND bijektiv bleiben.
    let orig = structNoiseCorpus()
    let cme = try BEN_CME.compress(orig)
    #expect(try BEN_CME.decompress(cme) == orig)
    let cm = try BEN_CM.compress(orig)
    #expect(cme.count < cm.count,
            "Zielfall: CME muss ncmm schlagen (\(cme.count) vs \(cm.count))")
  }

  @Test func unsafeCoderMatchesSafeBitExactly() throws {
    var orig = structNoiseCorpus(count: 1500)
    orig.append(Data(String(repeating: "safe und unsafe identisch ", count: 150).utf8))
    let safe = try BEN_CME.compress(orig, unsafeCoder: false)
    let fast = try BEN_CME.compress(orig, unsafeCoder: true)
    #expect(fast == safe, "unsafe-Coder muss bitidentische Ausgabe liefern")
    // kreuzweise: safe-Strom mit unsafe dekodieren und umgekehrt
    #expect(try BEN_CME.decompress(safe, unsafeCoder: true) == orig)
    #expect(try BEN_CME.decompress(fast, unsafeCoder: false) == orig)
  }

  @Test func rejectsCorruptHeader() {
    #expect(throws: (any Error).self) {
      _ = try BEN_CME.decompress(Data([0x00, 0x01]))   // zu kurz
    }
  }
}

// MARK: - SuffixArrayGPU (Nr. 58, Metal) — bitidentisch zur CPU

/// Alle Tests überspringen sich selbst, wenn Metal/Int64-ArgSort fehlt
/// (Linux-CI, ältere Macs) — dort deckt der CPU-Fallback die Semantik ab.
/// `.serialized`: die Pipeline-Tests tauschen NibbleBWT.gpuBuilder
/// (Threshold 0), das darf nicht parallel zu anderen Tests geschehen.
@Suite(.serialized) struct SuffixArrayGPUTests {

  @Test func gpuMatchesCPUOnCriticalCases() {
    guard SuffixArrayGPU.isAvailable else { return }
    let gpu = SuffixArrayGPU(gpuThreshold: 0)
    let cpu = SuffixArrayPrefixDoubling()

    var cases: [[Int]] = [
      [Int](repeating: 5, count: 2),
      [Int](repeating: 5, count: 17),
      [Int](repeating: 5, count: 1000),          // konstant: alle Rotationen gleich
      (0..<16).map { $0 % 2 == 0 ? 2 : 0 },       // ABAB: periodisch
      [1, 2, 3, 1, 2, 3],                          // ABCABC
      [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
      [4, 8, 6, 5, 6, 12, 6, 12, 6, 15],           // 'Hello'
    ]
    var rng = SeededRandom(state: 0xBE42_6970_0000_0001)
    for _ in 0..<8 {
      cases.append((0..<1500).map { _ in Int(rng.nextByte() & 0xF) })
    }
    for (i, text) in cases.enumerated() {
      #expect(gpu.build(text: text, alphabetSize: 16)
                == cpu.build(text: text, alphabetSize: 16),
              "GPU-SA weicht von CPU ab (Fall \(i), n=\(text.count))")
    }
  }

  @Test func gpuBelowThresholdDelegatesToCPU() {
    // Auch OHNE Metal gültig: unterhalb der Schwelle wird immer die CPU
    // genutzt — Ergebnis muss der reinen CPU entsprechen.
    let gpu = SuffixArrayGPU()   // Default-Schwelle 1 Mi Nibbles
    let cpu = SuffixArrayPrefixDoubling()
    let text = (0..<500).map { $0 % 13 % 16 }
    #expect(gpu.build(text: text, alphabetSize: 16)
              == cpu.build(text: text, alphabetSize: 16))
  }

  @Test func fullPipelineBitIdenticalWithGPU() async throws {
    guard SuffixArrayGPU.isAvailable else { return }
    let saved = NibbleBWT.gpuBuilder
    NibbleBWT.gpuBuilder = SuffixArrayGPU(gpuThreshold: 0)
    defer { NibbleBWT.gpuBuilder = saved }

    var rng = SeededRandom(state: 0xBE42_6970_0000_0002)
    var corpora: [Data] = [
      Data(String(repeating: "bitidentisch auf gpu und cpu ", count: 400).utf8),
      Data(repeating: 0x42, count: 3000),          // periodisch: Tiebreak-Pfad!
      rng.data(count: 8000),
    ]
    var mixed = corpora[0]; mixed.append(rng.data(count: 5000))
    corpora.append(mixed)

    for (i, orig) in corpora.enumerated() {
      let cpuOut = try BEN_NBCMBF.compress(orig, blockSize: 4096)
      let gpuOut = try BEN_NBCMBF.compress(orig, blockSize: 4096, useGPU: true)
      #expect(gpuOut == cpuOut, "GPU-Ausgabe nicht bitidentisch (Korpus \(i))")
      #expect(try BEN_NBCMBF.decompress(gpuOut) == orig)

      let par = try await BEN_NBCMBF.compressParallel(orig, blockSize: 4096,
                                                      threads: 4, useGPU: true)
      #expect(par == cpuOut, "GPU parallel nicht bitidentisch (Korpus \(i))")
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
    format.algorithm = .BEN_NBBMR
    var data = format.getHeader()
    data.append(contentsOf: [0x00])   // checkHeader verlangt > headerCount
    #expect(try format.checkHeader(in: data) == .BEN_NBBMR)
  }

  @Test func headerRoundtripBEN_MEC() throws {
    var format = be42()
    format.algorithm = .BEN_NBMEC
    var data = format.getHeader()
    data.append(contentsOf: [0x00])
    #expect(try format.checkHeader(in: data) == .BEN_NBMEC)
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
    format.algorithm = .BEN_NCMM
    var data = format.getHeader()
    data.append(contentsOf: [0x00])
    #expect(try format.checkHeader(in: data) == .BEN_NCMM)
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

  @Test func headerRoundtripBEN_NBCMBF() throws {
    var format = be42()
    format.algorithm = .BEN_NBCMBF
    var data = format.getHeader()
    data.append(contentsOf: [0x00])
    #expect(try format.checkHeader(in: data) == .BEN_NBCMBF)
  }

  @Test func headerRoundtripBEN_CME() throws {
    var format = be42()
    format.algorithm = .BEN_NCMME
    var data = format.getHeader()
    data.append(contentsOf: [0x00])
    #expect(try format.checkHeader(in: data) == .BEN_NCMME)
  }

  @Test func algorithmRawValues() {
    #expect(Algorithm.BEN_NBBMR.rawValue == "nbbmr")
    #expect(Algorithm.BEN_NBMEC.rawValue == "nbmec")
    #expect(Algorithm.BEN_NCMME.rawValue == "ncmme")
    #expect(Algorithm.BEN_NBCM.rawValue == "nbcm")
    #expect(Algorithm.BEN_NBCMB.rawValue == "nbcmb")
    #expect(Algorithm.BEN_NBCMBF.rawValue == "nbcmbf")
    #expect(Algorithm.BEN_NCMME.rawValue == "ncmme")
    #expect(Algorithm(rawValue: "ncmme") == .BEN_NCMME)
    #expect(Algorithm(rawValue: "nbmec") == .BEN_NBMEC)
    #expect(Algorithm(rawValue: "nbbmr") == .BEN_NBBMR)
    #expect(Algorithm(rawValue: "ncmm") == .BEN_NCMM)
    #expect(Algorithm(rawValue: "nbcm") == .BEN_NBCM)
    #expect(Algorithm(rawValue: "nbcmb") == .BEN_NBCMB)
    #expect(Algorithm(rawValue: "nbcmbf") == .BEN_NBCMBF)
    #expect(Algorithm(rawValue: "gibtsnicht") == nil)
  }
}
