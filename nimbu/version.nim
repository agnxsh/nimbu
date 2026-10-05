# nimbu
# Copyright (c) 2026 Agnish Ghosh
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

## Version tagging for nimbu binaries

import std/[os, strutils], beacon_chain/buildinfo

const
  versionMajor* = 0
  versionMinor* = 1
  versionBuild* = 0

  sourcePath = currentSourcePath.rsplit({DirSep, AltSep}, 1)[0]
  gitRevision* = strip(generateGitRevision(sourcePath))[0..5]

  versionAsStr* =
    $versionMajor & "." & $versionMinor & "." & $versionBuild

  fullVersionStr* = "v" & versionAsStr & "-" & gitRevision

  nimbuAgentStr* = "nimbu/" & fullVersionStr

  copyrights* =
    "Copyright (c) " &
    (if compileYear == "2026": "2026" else: "2026-" & compileYear) &
    " Agnish Ghosh"
