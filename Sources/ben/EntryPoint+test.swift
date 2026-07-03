// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Sebastian Ritter <bastie@users.noreply.github.com>

import be42

enum TestError : Error {
  case testFailed
}

// put selftest into single source to make the work better readable
extension ben {
  
  func runSelfTest (for algorithm: Algorithm) async throws -> Result<Void, Error>{
    var passed = true

    switch algorithm {
    case .BEN_BWT:
      passed = SuffixArrayTest.selfTest() && passed
      passed = NibbleBWT.selfTest() && passed
      passed = BEN_BWT.selfTest() && passed
    case .BEN_MEC:
      passed = SuffixArrayTest.selfTest() && passed
      passed = NibbleBWT.selfTest() && passed
      passed = BEN_MEC.selfTest() && passed
    case .BEN_CM:
      passed = BEN_CM.selfTest() && passed   // kein BWT in der Pipeline
    case .BEN_NBCM:
      passed = SuffixArrayTest.selfTest() && passed
      passed = NibbleBWT.selfTest() && passed
      passed = BEN_NBCM.selfTest() && passed
    case .BEN_NBCMB:
      passed = SuffixArrayTest.selfTest() && passed
      passed = NibbleBWT.selfTest() && passed
      passed = BEN_NBCM.selfTest() && passed
      passed = BEN_NBCMB.selfTest() && passed
    }

    guard passed else {
      return .failure(TestError.testFailed)
    }
    return .success(Void())
  }
}
