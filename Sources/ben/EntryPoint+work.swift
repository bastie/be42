// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Sebastian Ritter <bastie@users.noreply.github.com>

import be42
import Foundation

// put the work into separate source to make it more readable
extension ben {
  
  func work(with algorithm: Algorithm) async throws {
    var fileformat = be42()
    var input = try Data(contentsOf: URL(fileURLWithPath: file!))

    if !decompress { // MARK: Compression
      fileformat.algorithm = algorithm
      let rawData: Data
      switch algorithm {
      case .BEN_BWT: rawData = try BEN_BWT.compress(input)
      case .BEN_MEC: rawData = try BEN_MEC.compress(input)
      case .BEN_CM:  rawData = try BEN_CM.compress(input)
      case .BEN_NBCM: rawData = try BEN_NBCM.compress(input)
      case .BEN_NBCMB: rawData = try BEN_NBCMB.compress(input,
                                                        blockSize: blocksize * 1024 * 1024)
      }
      let newFileName = "\(file!).ben"
      let output = URL(fileURLWithPath: newFileName)
      var data = Data(fileformat.getHeader())
      data.append(rawData)
      try data.write(to: output)
    }
    else { // MARK: Decompression
      // Der Algorithmus steht in der Datei — nicht auf der Kommandozeile.
      let algorithmInFile = try fileformat.checkHeader(in: [UInt8](input))
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

      let decompressed: Data
      switch algorithmInFile {
      case .BEN_BWT: decompressed = try BEN_BWT.decompress(input)
      case .BEN_MEC: decompressed = try BEN_MEC.decompress(input)
      case .BEN_CM:  decompressed = try BEN_CM.decompress(input)
      case .BEN_NBCM: decompressed = try BEN_NBCM.decompress(input)
      case .BEN_NBCMB: decompressed = try BEN_NBCMB.decompress(input)
      }
      try decompressed.write(to: output)
    }
  }
}

