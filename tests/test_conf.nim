# nimbu
# Copyright (c) 2026 Agnish Ghosh
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}
{.used.}

import
  unittest2,
  ../nimbu/conf

const pubkeyHex =
  "0xa99a76ed7796f7be22d5b7e85deeb7c5677e88e511e0b337618f8c4eb61349b4" &
  "bf2d153f649f7b53359fe8b94a38e44c"

proc load(args: varargs[string]): NimbuConf {.raises: [CatchableError].} =
  NimbuConf.load(cmdLine = @args, printUsage = false, quitOnFailure = false)

suite "Configuration":
  test "defaults":
    let config = load()
    check:
      config.logLevel == "INFO"
      config.logFormat == StdoutLogKind.Auto
      config.network == "mainnet"
      config.beaconNodeUrls().get() == @[DefaultBeaconNode]
      not config.publicBeaconNode
      config.builderPubkey.isNone

  test "repeated beacon nodes, builder key and log format":
    let config = load(
      "--beacon-node=http://a:5052", "--beacon-node=http://b:5052",
      "--builder-pubkey=" & pubkeyHex, "--log-format=json")
    check:
      config.beaconNodeUrls().get() == @["http://a:5052", "http://b:5052"]
      config.builderPubkey.isSome
      config.logFormat == StdoutLogKind.Json

  test "--public-beacon-node picks the network's public endpoint":
    check:
      load("--network=sepolia", "--public-beacon-node").beaconNodeUrls()
        .get() == @["https://beacon.sepolia.ethpandaops.io"]
      load("--network=plataberget", "--public-beacon-node",
           "--beacon-node=http://local:5052").beaconNodeUrls().get() ==
        @["http://local:5052",
          "https://beacon.glamsterdam-devnet-8.ethpandaops.io"]
      load("--network=mainnet", "--public-beacon-node")
        .beaconNodeUrls().isErr()

  test "invalid builder keys are rejected":
    expect CatchableError:
      discard load("--builder-pubkey=0x1234")

  test "log level directives":
    check:
      setupLogging("debug", StdoutLogKind.NoColors).isOk()
      setupLogging("INFO;DEBUG:chain", StdoutLogKind.NoColors).isOk()
      setupLogging("verbose", StdoutLogKind.NoColors).isErr()
