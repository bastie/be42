// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Sebastian Ritter <bastie@users.noreply.github.com>

public enum Algorithm : RawRepresentable, CustomStringConvertible, CustomDebugStringConvertible {
  
  public var debugDescription: String {
    return Algorithm.long(of: rawValue) ?? "nil"
  }
  
  static let _BEN_BWT = "nibble.bwt.birthday.markov.rans-pass2"
  static let _all = [
    _BEN_BWT
  ]
  
  case BEN_BWT
  
  public var description: String {
    return rawValue
  }
  public var rawValue: String {
    switch self {
    case .BEN_BWT: return Algorithm.short(of: Algorithm._BEN_BWT)
    }
  }
  
  public typealias RawValue = String
  
  public init?(rawValue: String) {
    switch rawValue {
    case Algorithm.short(of: Algorithm._BEN_BWT) : self = .BEN_BWT
    default: return nil
    }
  }
  
  static func short(of: String) -> String {
    return of.split(separator: ".").compactMap { $0.first }.map { String($0) }.joined()
  }
  
  static func long (of: String) -> String? {
    for candidate in Algorithm._all {
      if short(of: candidate) == of {
        return candidate
      }
    }
    return nil
  }
}


public enum AlgorithmError : Error {
  case UnknownAlgorithm
}
