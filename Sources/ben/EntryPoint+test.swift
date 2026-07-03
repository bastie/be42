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
    passed = SuffixArrayTest.selfTest() && passed
    passed = NibbleBWT.selfTest() && passed

    switch algorithm {
    case .BEN_BWT:
      passed = BEN_BWT.selfTest() && passed
    case .BEN_MEC:
      passed = BEN_MEC.selfTest() && passed
    }

    guard passed else {
      return .failure(TestError.testFailed)
    }
    return .success(Void())
  }
}
