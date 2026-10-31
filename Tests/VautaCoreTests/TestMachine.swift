// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Darwin

/// The machine the tests run on. The CI runners are virtual machines: their GPU (Apple's paravirtual device) sometimes rounds the same
/// bf16 sums differently from one run to the next, and their few cores, shared by the whole parallel suite with code coverage on, run
/// debug code tens of times slower than a Mac. A bound measured on a Mac is kept there; on a virtual machine it is widened, never dropped.
enum TestMachine {
    static let isVirtual: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 && value == 1
    }()
}
