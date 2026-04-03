// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Sebastian Ritter <bastie@users.noreply.github.com>

import be42
import Foundation

// put the work into separate source to make it more readable
extension ben {
  
  func work(with algorithm: Algorithm) async throws {
    let fileformat = be42()
    var input = try Data(contentsOf: URL(fileURLWithPath: file!))
    
    if !decompress { // MARK: Compression
      guard algorithm == .BEN_BWT else {
        throw AlgorithmError.UnknownAlgorithm
      }
      let rawData = try BEN_BWT.compress(input)
      let newFileName = "\(file!).ben"
      let output = URL(fileURLWithPath: newFileName)
      var data = Data(fileformat.getHeader())
      data.append(rawData)
      try data.write(to: output)
    }
    else { // MARK: Decompression
      switch try fileformat.checkHeader(in: [UInt8](input)) {
      
      case .BEN_BWT:
        for _ in 0..<fileformat.headerCount {
          _ = input.popFirst()
        }
        
        var newFileName = file!
        if newFileName.lowercased().hasSuffix(".ben"){
          newFileName.removeLast(".ben".count)
        }
        else {
          newFileName.append(".neb")
        }
        let output = URL(fileURLWithPath: newFileName)
        
        try BEN_BWT.decompress(input).write(to: output)
        
      //default: throw AlgorithmError.UnknownAlgorithm
      }
    }
  }
}

