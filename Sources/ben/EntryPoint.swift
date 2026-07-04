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
      version: "0.50.0",
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
          help: "Block size in MiB for nbcmb (bigger = better ratio, smaller = more parallelism/less RAM). Default: automatic from file size and threads, 8...64 MiB")
  var blocksize : Int? = nil

  @Option(name: [.customShort("T"), .customLong("threads")],
          help: "Parallel blocks for nbcmb, 0 = number of CPU cores (mind RAM: ~36 bytes per input byte per parallel block)")
  var threads : Int = 0

  @Flag(name: [.customLong("unsafe")],
        help: "Use pointer-based hot loops without bounds checks (same output, faster; you accept the safety trade-off)")
  var unsafeCoder = false
  
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
      print (algorithm, terminator: "")
      print ("\",")
      print ("\"version\": \"\(ben.configuration.version)\"", terminator: ",\n")
      print ("\"threads\": \"\(threads)\"", terminator: ",\n")
      print ("\"unsafe\": \"\(unsafeCoder)\"", terminator: ",\n")
      print ("\"blocksize\": \"\(blocksize?.description ?? "automatic")\"")
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

    if let blocksize {
      guard (1...2048).contains(blocksize) else {
        throw ValidationError("Block size must be 1...2048 MiB: \(blocksize)")
      }
    }

    guard (0...256).contains(threads) else {
      throw ValidationError("Threads must be 0...256: \(threads)")
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




