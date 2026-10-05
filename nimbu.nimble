# nimbu
# Copyright (c) 2026 Agnish Ghosh
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

mode = ScriptMode.Verbose

version       = "0.1.0"
author        = "Agnish Ghosh"
description   = "External Gloas (EIP-7732 / ePBS) payload builder built on nimbus-eth2"
license       = "MIT or Apache License 2.0"
bin           = @["nimbu/nimbu"]

# Documentation only: builds use the pinned submodules in `vendor/` through
# nimbus-build-system (`make`), never Nimble - see notes/0004
requires(
  "nim == 2.2.12",
  "chronicles",
  "chronos",
  "confutils",
  "results",
  "stew",
  "unittest2"
)
