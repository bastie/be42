// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Sebastian Ritter <bastie@users.noreply.github.com>

public enum Algorithm : RawRepresentable, CustomStringConvertible, CustomDebugStringConvertible {
  
  public var debugDescription: String {
    return Algorithm.long(of: rawValue) ?? "nil"
  }
  
  static let _BEN_NBBMR = "nibble.bwt.birthday.markov.rans-pass2"
  static let _BEN_NBMEC = "nibble.bwt.markov.exclusion.cabac"
  static let _BEN_NCMM  = "nibble.context.mixing.match"
  static let _BEN_NBCM = "nibble.bwt.chain.mixing"
  static let _BEN_NBCMB = "nibble.bwt.chain.mixing.blocks"
  static let _BEN_NBCMBF = "nibble.bwt.chain.mixing.blocks.filtered"
  static let _BEN_NCMME = "nibble.context.mixing.match.extended"
  static let _all = [
    _BEN_NBBMR,
    _BEN_NBMEC,
    _BEN_NCMM,
    _BEN_NBCM,
    _BEN_NBCMB,
    _BEN_NBCMBF,
    _BEN_NCMME
  ]

  case BEN_NBBMR
  case BEN_NBMEC
  case BEN_NCMM
  case BEN_NBCM
  case BEN_NBCMB
  case BEN_NBCMBF
  case BEN_NCMME

  public var description: String {
    return rawValue
  }
  public var rawValue: String {
    switch self {
    case .BEN_NBBMR: return Algorithm.short(of: Algorithm._BEN_NBBMR)
    case .BEN_NBMEC: return Algorithm.short(of: Algorithm._BEN_NBMEC)
    case .BEN_NCMM:  return Algorithm.short(of: Algorithm._BEN_NCMM)
    case .BEN_NBCM: return Algorithm.short(of: Algorithm._BEN_NBCM)
    case .BEN_NBCMB: return Algorithm.short(of: Algorithm._BEN_NBCMB)
    case .BEN_NBCMBF: return Algorithm.short(of: Algorithm._BEN_NBCMBF)
    case .BEN_NCMME: return Algorithm.short(of: Algorithm._BEN_NCMME)
    }
  }

  public typealias RawValue = String

  public init?(rawValue: String) {
    switch rawValue {
    case Algorithm.short(of: Algorithm._BEN_NBBMR) : self = .BEN_NBBMR
    case Algorithm.short(of: Algorithm._BEN_NBMEC) : self = .BEN_NBMEC
    case Algorithm.short(of: Algorithm._BEN_NCMM)  : self = .BEN_NCMM
    case Algorithm.short(of: Algorithm._BEN_NBCM): self = .BEN_NBCM
    case Algorithm.short(of: Algorithm._BEN_NBCMB): self = .BEN_NBCMB
    case Algorithm.short(of: Algorithm._BEN_NBCMBF): self = .BEN_NBCMBF
    case Algorithm.short(of: Algorithm._BEN_NCMME): self = .BEN_NCMME
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
