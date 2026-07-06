// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Sebastian Ritter <bastie@users.noreply.github.com>

// GPU-beschleunigte Suffix-Array-Konstruktion (Katalog Nr. 58) — Swift 6
//
// Prefix-Doubling wie SuffixArrayPrefixDoubling, aber die dominante
// Sortierung (zwei stabile Counting-Sorts je Runde, ~70 % der Laufzeit)
// wird durch EINEN MPSGraph-ArgSort über gepackte Int64-Schlüssel ersetzt:
//
//     key[i] = rank[i] << 32 | rank[(i+gap) mod n]
//
// BITIDENTITÄT ZUR CPU — per Konstruktion, nicht per Hoffnung:
//
//   1. Die Rangvergabe je Runde hängt NUR von Schlüssel-GLEICHHEIT
//      benachbarter Elemente in sortierter Ordnung ab — die Reihenfolge
//      INNERHALB einer Gleichstands-Gruppe ist für die neuen Ränge
//      irrelevant. Ein instabiler ArgSort liefert deshalb exakt dieselbe
//      Rang-Evolution wie die stabilen CPU-Counting-Sorts.
//   2. Der Int64-Schlüssel packt das Paar (rank, rank2) injektiv
//      (beide < n ≤ 2^31): Int64-Vergleich == lexikografischer
//      Paarvergleich. Keine Float-Präzisionsfragen.
//   3. Einziger Punkt, an dem Stabilität sichtbar wird: verbleibende
//      Gleichstände am ENDE (identische Rotationen, periodische Eingaben)
//      — die CPU ordnet sie per Stabilität nach Startindex, und der
//      BWT-Index hängt davon ab. Deshalb wird das finale SA IMMER aus den
//      finalen Rängen normalisiert: ein stabiler CPU-Counting-Sort der
//      Identität nach Rang == Ordnung (Rang, Index) == exakte
//      CPU-Semantik. Sind alle Ränge eindeutig, genügt ein Scatter.
//
// VERFÜGBARKEIT: MPSGraph-ArgSort existiert seit macOS 13; ob Int64-
// Schlüssel unterstützt werden, ist nicht dokumentiert → einmalige
// Laufzeit-Probe (Mini-ArgSort mit >32-Bit-Schlüsseln, Korrektheit wird
// verifiziert). Schlägt sie fehl oder gibt es kein Metal-Device, fällt
// build() transparent auf SuffixArrayPrefixDoubling zurück — die Ausgabe
// bleibt in jedem Fall bitidentisch, --gpu ist reine Beschleunigung.
//
// UNIFIED MEMORY: Schlüssel-Puffer ist storageModeShared — die CPU
// schreibt die Schlüssel direkt in denselben Speicher, den die GPU
// sortiert; kein Kopiertransfer. Der Rang-Scan (sequenzielle Abhängigkeit)
// bleibt bewusst auf der CPU.
//
// SCHWELLE: unterhalb gpuThreshold Nibbles lohnt der Graph-Overhead
// nicht — CPU-Pfad (Ergebnis identisch). Tests setzen die Schwelle auf 0.

import Foundation

#if canImport(MetalPerformanceShadersGraph)

import Metal
import MetalPerformanceShadersGraph

public struct SuffixArrayGPU: SuffixArrayBuilder, Sendable {

  /// Ab dieser Nibble-Anzahl wird die GPU bemüht (darunter: CPU-Pfad,
  /// Ergebnis identisch). Default ~1 Mi Nibbles = 512 KiB Eingabe.
  public let gpuThreshold: Int

  public init(gpuThreshold: Int = 1 << 20) {
    self.gpuThreshold = gpuThreshold
  }

  /// MTLDevice ist laut Metal-Dokumentation threadsicher; das Handle wird
  /// einmalig erzeugt und nur gelesen.
  private static let device: (any MTLDevice)? =
    MTLCreateSystemDefaultDevice()

  /// Einmalige Laufzeit-Probe: existiert ein Metal-Device UND sortiert
  /// MPSGraph-ArgSort Int64-Schlüssel korrekt (inkl. Bits oberhalb von 32)?
  /// Verifiziert Permutations-Eigenschaft und aufsteigende Schlüsselfolge —
  /// mehr wird vom Algorithmus nicht vorausgesetzt (siehe Kopfkommentar).
  public static let isAvailable: Bool = {
    guard let device = SuffixArrayGPU.device else { return false }
    // Schlüssel so gewählt, dass Int32-Truncation ODER Float32-Rundung
    // die Ordnung umkehren würde:
    let keys: [Int64] = [(5 << 32) | 1, 7, (5 << 32) | 0, (1 << 40) + 1,
                         (1 << 40), 7, 0]
    guard let sorted = SuffixArrayGPU.gpuArgSort(keys: keys, device: device) else {
      return false
    }
    guard Set(sorted) == Set(0 ..< keys.count) else { return false }
    for i in 1 ..< keys.count where keys[sorted[i - 1]] > keys[sorted[i]] {
      return false
    }
    return true
  }()

  // ───────────────────────────────────────────────────────────────────────────
  // MARK: ArgSort über MPSGraph
  // ───────────────────────────────────────────────────────────────────────────

  /// Sortiert `keys` aufsteigend, liefert die Index-Permutation.
  /// `nil` bei jedem Fehler (Aufrufer fällt auf CPU zurück).
  private static func gpuArgSort(keys: [Int64],
                                 device: any MTLDevice) -> [Int]? {
    let n = keys.count
    guard n > 0,
          let buffer = device.makeBuffer(length: n * MemoryLayout<Int64>.stride,
                                         options: .storageModeShared) else {
      return nil
    }
    keys.withUnsafeBufferPointer { src in
      buffer.contents().copyMemory(from: src.baseAddress!,
                                   byteCount: n * MemoryLayout<Int64>.stride)
    }
    let graph = MPSGraph()
    let shape = [NSNumber(value: n)]
    let ph = graph.placeholder(shape: shape, dataType: .int64, name: nil)
    let arg = graph.argSort(ph, axis: 0, descending: false, name: nil)
    let feed = MPSGraphTensorData(buffer, shape: shape, dataType: .int64)
    let results = graph.run(feeds: [ph: feed],
                            targetTensors: [arg],
                            targetOperations: nil)
    guard let out = results[arg] else { return nil }
    var idx32 = [Int32](repeating: 0, count: n)
    idx32.withUnsafeMutableBufferPointer { p in
      out.mpsndarray().readBytes(p.baseAddress!, strideBytes: nil)
    }
    return idx32.map { Int($0) }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // MARK: Build (Prefix-Doubling, GPU-Sortierung)
  // ───────────────────────────────────────────────────────────────────────────

  public func build(text: [Int], alphabetSize: Int) -> [Int] {
    let n = text.count
    if n == 0 { return [] }
    if n == 1 { return [0] }
    precondition(n <= Int(Int32.max), "SuffixArrayGPU: n > Int32.max")

    guard SuffixArrayGPU.isAvailable, n >= gpuThreshold,
          let device = SuffixArrayGPU.device else {
      return SuffixArrayPrefixDoubling().build(text: text,
                                               alphabetSize: alphabetSize)
    }

    // ── Initiale dichte Ränge aus Zeichenwerten (CPU, O(n)) ──────────────────
    // Entspricht exakt dem ersten Counting-Sort + Rangvergabe der CPU:
    // dichter Rang eines Zeichens = Anzahl kleinerer vorkommender Zeichen.
    var histogram = [Int](repeating: 0, count: alphabetSize)
    for v in text { histogram[v] += 1 }
    var denseValue = [Int32](repeating: 0, count: alphabetSize)
    var numDistinct = 0
    for v in 0 ..< alphabetSize where histogram[v] > 0 {
      denseValue[v] = Int32(numDistinct)
      numDistinct += 1
    }
    var rank = [Int32](repeating: 0, count: n)
    for i in 0 ..< n { rank[i] = denseValue[text[i]] }

    if numDistinct == n {                     // nur möglich bei n ≤ Alphabet
      return finalize(rank: rank, numDistinct: numDistinct, n: n)
    }

    // ── GPU-Rundenapparat: Graph + geteilter Schlüsselpuffer, einmalig ──────
    guard let keyBuffer = device.makeBuffer(
            length: n * MemoryLayout<Int64>.stride,
            options: .storageModeShared) else {
      return SuffixArrayPrefixDoubling().build(text: text,
                                               alphabetSize: alphabetSize)
    }
    let graph = MPSGraph()
    let shape = [NSNumber(value: n)]
    let ph = graph.placeholder(shape: shape, dataType: .int64, name: nil)
    let arg = graph.argSort(ph, axis: 0, descending: false, name: nil)
    let feed = MPSGraphTensorData(keyBuffer, shape: shape, dataType: .int64)
    let keys = keyBuffer.contents().bindMemory(to: Int64.self, capacity: n)
    var sa32 = [Int32](repeating: 0, count: n)

    // ── Verdopplung ─────────────────────────────────────────────────────────
    var gap = 1
    while gap < n {
      // Schlüssel direkt in den geteilten GPU-Puffer schreiben (kein Kopieren)
      rank.withUnsafeBufferPointer { r in
        let split = n - gap
        for i in 0 ..< split {
          keys[i] = Int64(r[i]) << 32 | Int64(r[i + gap])
        }
        for i in split ..< n {
          keys[i] = Int64(r[i]) << 32 | Int64(r[i + gap - n])
        }
      }

      // GPU: ArgSort der gepackten Paare (Stabilität irrelevant, s. Kopf)
      let results = graph.run(feeds: [ph: feed],
                              targetTensors: [arg],
                              targetOperations: nil)
      guard let out = results[arg] else {
        return SuffixArrayPrefixDoubling().build(text: text,
                                                 alphabetSize: alphabetSize)
      }
      sa32.withUnsafeMutableBufferPointer { p in
        out.mpsndarray().readBytes(p.baseAddress!, strideBytes: nil)
      }

      // CPU: dichte Neu-Ränge (nur Schlüssel-GLEICHHEIT der Nachbarn zählt)
      var newRank = [Int32](repeating: 0, count: n)
      newRank[Int(sa32[0])] = 0
      numDistinct = 1
      for i in 1 ..< n {
        let a = Int(sa32[i - 1]), b = Int(sa32[i])
        if keys[a] != keys[b] { numDistinct += 1 }
        newRank[b] = Int32(numDistinct - 1)
      }
      rank = newRank

      if numDistinct == n { break }
      gap *= 2
    }

    return finalize(rank: rank, numDistinct: numDistinct, n: n)
  }

  // ───────────────────────────────────────────────────────────────────────────
  // MARK: Finalisierung — exakte CPU-Tiebreak-Semantik
  // ───────────────────────────────────────────────────────────────────────────

  /// Normalisiert das SA aus den finalen Rängen. Eindeutige Ränge → direkter
  /// Scatter. Verbleibende Gleichstände (identische Rotationen, periodische
  /// Eingaben) → stabiler Counting-Sort der Identität nach Rang, also
  /// Ordnung (Rang, Index aufsteigend) — identisch zur CPU-Kette stabiler
  /// Sorts. Der BWT-Index hängt genau hiervon ab.
  private func finalize(rank: [Int32], numDistinct: Int, n: Int) -> [Int] {
    var sa = [Int](repeating: 0, count: n)
    if numDistinct == n {
      for i in 0 ..< n { sa[Int(rank[i])] = i }
      return sa
    }
    var start = [Int](repeating: 0, count: numDistinct)
    for i in 0 ..< n { start[Int(rank[i])] += 1 }
    var sum = 0
    for k in 0 ..< numDistinct {
      let c = start[k]
      start[k] = sum
      sum += c
    }
    for i in 0 ..< n {                     // Identitätsreihenfolge → stabil
      let k = Int(rank[i])
      sa[start[k]] = i
      start[k] += 1
    }
    return sa
  }
}

#else   // Kein MetalPerformanceShadersGraph (z.B. Linux-CI)

/// Stub ohne Metal: identische Schnittstelle, delegiert immer an die CPU.
/// `isAvailable == false` — die CLI meldet das bei --gpu.
public struct SuffixArrayGPU: SuffixArrayBuilder, Sendable {

  public let gpuThreshold: Int

  public init(gpuThreshold: Int = 1 << 20) {
    self.gpuThreshold = gpuThreshold
  }

  public static let isAvailable = false

  public func build(text: [Int], alphabetSize: Int) -> [Int] {
    return SuffixArrayPrefixDoubling().build(text: text,
                                             alphabetSize: alphabetSize)
  }
}

#endif
