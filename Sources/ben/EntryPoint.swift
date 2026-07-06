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
      abstract: "Kompressionswerkzeug auf Basis einer anderen Sichtweise: der natürlichen Nibble-Struktur jeder Datei",
      discussion:
      """
      Copyright © 2026 Sebastian Ritter
      License Apache 2.0 
      """,
      version: "0.52.0",
      helpNames: .long
    )
  }
  
  @Flag(name: [.customLong("selftest")], help: "Testet die Algorithmus-Bausteine")
  var selfTest = false

  @Flag(name: [.customShort("d"), .customLong ("decompress")], help: "Dekomprimiert die Datei.")
  var decompress = false

  @Flag(name: [.customLong("v"), .customLong("verbose")], help: "Ausführliche Ausgabe")
  var verbose = false

  @Option(name: [.customLong("algorithm")], help: "Algorithmus")
  var algorithm : String = Algorithm.BEN_NBCMBF.rawValue

  @Option(name: [.customLong("blocksize")],
          help: "Blockgröße in MiB für nbcmb/nbcmbf (größer = bessere Ratio, kleiner = mehr Parallelität/weniger RAM). Standard: automatisch aus Dateigröße und Threads, 8...64 MiB")
  var blocksize : Int? = nil

  @Option(name: [.customShort("T"), .customLong("threads")],
          help: "Parallele Blöcke für nbcmb/nbcmbf, 0 = Anzahl CPU-Kerne (RAM beachten: ~36 Bytes je Eingabe-Byte je parallelem Block)")
  var threads : Int = 0

  @Flag(name: [.customLong("unsafe")],
        help: "Pointerbasierte Hot Loops ohne Bounds-Checks (gleiche Ausgabe, schneller; Sicherheits-Kompromiss wird akzeptiert)")
  var unsafeCoder = false

  @Flag(name: [.customLong("gpu")],
        help: "Metal-beschleunigte Suffix-Sortierung auf Apple Silicon (gleiche Ausgabe, bitidentisch zur CPU; fällt automatisch auf CPU zurück wenn nicht verfügbar)")
  var gpu = false

  @Argument(help: "Eingabedatei")
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




