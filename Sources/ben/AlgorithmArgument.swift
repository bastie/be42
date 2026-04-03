// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Sebastian Ritter <bastie@users.noreply.github.com>

import be42
import ArgumentParser

// I do not want dependency between be42 and swift argument parser and place the conform to protocoll as an extension into my enum here
extension Algorithm : ExpressibleByArgument {
}
