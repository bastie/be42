// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Sebastian Ritter <bastie@users.noreply.github.com>

import be42

enum TestError : Error {
  case testFailed
}

// put selftest into single source to make the work better readable
extension ben {
  
  func runSelfTest (for algorithm: Algorithm) async throws -> Result<Void, Error>{
    switch algorithm {
    case .BEN_BWT:
      SuffixArrayTest.selfTest()
      NibbleBWT.selfTest()
      BEN_BWT.selfTest()
      
    //default: return .failure(TestError.testFailed) // NOTE: maybe later required
    }
    
    return .success(Void())
  }
}
