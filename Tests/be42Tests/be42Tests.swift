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

  @Test func algorithmRawValues() {
    #expect(Algorithm.BEN_BWT.rawValue == "nbbmr")
    #expect(Algorithm.BEN_MEC.rawValue == "nbmec")
    #expect(Algorithm(rawValue: "nbmec") == .BEN_MEC)
    #expect(Algorithm(rawValue: "nbbmr") == .BEN_BWT)
    #expect(Algorithm(rawValue: "gibtsnicht") == nil)
  }
}
