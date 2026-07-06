// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Sebastian Ritter <bastie@users.noreply.github.com>

public enum be42FormatError : Error {
  case headerNotFound
  case illegalMagicBytes
  case unknownVersion
  case unknownAlgorithm
}

public struct be42 {
  
  public init(){}
  
  private let availableVersion = [
    0x00 : "unset version",
    0x01 : "version 1",
    0xFF : "reserved",
  ]
  private let availableAlgorithm = [
    0x00 : "unset algorithm",
    0x01 : Algorithm.BEN_BWT.rawValue,
    0x02 : Algorithm.BEN_MEC.rawValue,
    0x03 : Algorithm.BEN_CM.rawValue,
    0x04 : Algorithm.BEN_NBCM.rawValue,
    0x05 : Algorithm.BEN_NBCMB.rawValue,
    0x06 : Algorithm.BEN_NBCMBF.rawValue,
    0xFF : "reserved",
  ]
  public static let MAGIC : [UInt8] = [0xBE, 0x42]
  public var version : UInt8 = 0x01
  public var algorithm : Algorithm = .BEN_NBCMBF


  public var headerCount: Int {
    return getHeader().count
  }

  /// Format-Byte des Algorithmus im Container-Header.
  public static func code(of algorithm: Algorithm) -> UInt8 {
    switch algorithm {
    case .BEN_BWT: return 0x01
    case .BEN_MEC: return 0x02
    case .BEN_CM:  return 0x03
    case .BEN_NBCM: return 0x04
    case .BEN_NBCMB: return 0x05
    case .BEN_NBCMBF: return 0x06
    }
  }

  public func getHeader() -> [UInt8] {
    var result = [UInt8]()
    result.append(contentsOf: be42.MAGIC)
    result.append(version)
    result.append(be42.code(of: algorithm))
    return result
  }

  public func checkHeader (in data : [UInt8]) throws -> Algorithm {
    guard data.count > getHeader().count else {
      throw be42FormatError.headerNotFound
    }
    guard data[0] == 0xBE && data[1] == 0x42 else {
      throw be42FormatError.illegalMagicBytes
    }
    guard data[2] >= 0x01 && data[2] <= 0x01 else {
      throw be42FormatError.unknownVersion
    }

    switch data[3] {
    case 0x01: return .BEN_BWT
    case 0x02: return .BEN_MEC
    case 0x03: return .BEN_CM
    case 0x04: return .BEN_NBCM
    case 0x05: return .BEN_NBCMB
    case 0x06: return .BEN_NBCMBF
    default:
      throw be42FormatError.unknownAlgorithm
    }
  }
}
