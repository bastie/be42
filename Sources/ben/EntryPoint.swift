// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Sebastian Ritter <bastie@users.noreply.github.com>

import be42
import ArgumentParser
import Foundation

/// This is the application controller and separate the preconditions of CLI , the selftest and the work from the **be42 algorithm**
@main
struct ben : AsyncParsableCommand {
  
  static var configuration: CommandConfiguration {
    CommandConfiguration(
      commandName: "ben",
      abstract: "Compression utility based on another way of view called natural nibble structure of any file",
      discussion:
      """
      Copyright © 2026 Sebastian Ritter
      License Apache 2.0 
      """,
      version: "0.48.0",
      helpNames: .long
    )
  }
  
  @Flag(name: [.customLong("selftest")], help: "test algorithm parts")
  var selfTest = false
  
  @Flag(name: [.customShort("d"), .customLong ("decompress")], help: "Decompress the file.")
  var decompress = false
  
  @Flag(name: [.customLong("v"), .customLong("verbose")], help: "Verbose")
  var verbose = false
  
  @Option(name: [.customLong("algorithm")], help: "Algorithm")
  var algorithm : String = Algorithm.BEN_NBCMB.rawValue

  @Option(name: [.customLong("blocksize")],
          help: "Block size in MiB for nbcmb (bigger = better ratio, smaller = less RAM)")
  var blocksize : Int = 64
  
  @Argument(help: "input file")
  var file: String?
  
  func run() async throws {
    try await checkCommandLine()
    
    // check command line test available algorithm
    let compressionAlgorithm : Algorithm = Algorithm(rawValue: algorithm)!

    if selfTest || file == nil {
      switch try await runSelfTest(for: compressionAlgorithm) {
      case .failure : throw ExitCode.failure
      case .success : Foundation.exit(0)
      }
    }
    
    guard file != nil else {
      throw ValidationError("Missing file")
    }

    if verbose {
      print ("{")
      print ("\"name\": \"\(ben.configuration.commandName!)\",")
      print ("\"algorithm\": \"",terminator: "")
      debugPrint(algorithm, terminator: "")
      print("\",")
      print ("\"version\": \"\(ben.configuration.version)\"")
    }
    
    // the work
    try await self.work(with: compressionAlgorithm)
    
    if verbose {
      print ("}")
    }
    
  }
  
  func checkCommandLine() async throws {
    let compressionAlgorithm : Algorithm? = Algorithm(rawValue: algorithm)
    guard compressionAlgorithm != nil else {
      throw ValidationError("Unknown algorithm: \(algorithm)")
    }

    guard (1...2048).contains(blocksize) else {
      throw ValidationError("Block size must be 1...2048 MiB: \(blocksize)")
    }
    
    if let file {
      guard FileManager.default.fileExists(atPath: file) else {
        throw ValidationError("File not exists: \(file)")
      }
      
      guard FileManager.default.isReadableFile(atPath: file) else {
        throw ValidationError("File not readable: \(file)")
      }
      
      let directory = {
        let path = URL(filePath: file).path()
        if path == "" {
          return "."
        }
        return path
      }()
      guard FileManager.default.isWritableFile(atPath: directory) else {
        throw ValidationError("Directory not writable: \(directory)")
      }
    }
  }
}




