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
    0xFF : "reserved",
  ]
  public static let MAGIC : [UInt8] = [0xBE, 0x42]
  public var version : UInt8 = 0x01
  public var algorithm : Algorithm = .BEN_BWT
  
  
  public var headerCount: Int {
    return getHeader().count
  }
  
  public func getHeader() -> [UInt8] {
    var result = [UInt8]()
    result.append(contentsOf: be42.MAGIC)
    result.append(version)
    result.append(0x01)
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
    default:
      throw be42FormatError.unknownAlgorithm
    }
  }
}
