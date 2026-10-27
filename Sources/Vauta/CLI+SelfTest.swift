// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

/// `Vauta mlx-selftest [--model]` (not listed in `--help`): the GPU kernels, and with `--model` the installed search model, run
/// in the binary as shipped. Exit codes: 0 pass, 1 fail, 2 unsupported, 3 model missing. It never opens the store, never
/// records and never uses the network.
func mlxSelfTest(_ invocation: CommandInvocation) async -> Int32 {
    if invocation.has("--download") {
        let fetched = await SearchModelSelfTest.download()
        fetched.lines.forEach { print($0) }
        return fetched.exitCode
    }
    let result = await SearchModelSelfTest.run(includeModel: invocation.has("--model"))
    result.lines.forEach { print($0) }
    return result.exitCode
}
