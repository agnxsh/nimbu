# nimbu
# Copyright (c) 2026 Agnish Ghosh
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

## Command line configuration - see notes/0001-architecture-flow.md §4.11

import
  std/options,
  confutils, results,
  beacon_chain/spec/crypto,
  ./logging

export options, confutils, results, crypto, logging

const
  DefaultBeaconNode* = "http://127.0.0.1:5052"

type
  NimbuConf* = object
    logLevel* {.
      desc: "Sets the log level, optionally per topic, e.g. " &
            "\"INFO;DEBUG:chain\" (TRACE, DEBUG, INFO, NOTICE, WARN, " &
            "ERROR, FATAL)"
      defaultValue: "INFO"
      name: "log-level" .}: string

    logFormat* {.
      desc: "Log output format (auto, colors, nocolors, json)"
      defaultValueDesc: "auto"
      defaultValue: StdoutLogKind.Auto
      name: "log-format" .}: StdoutLogKind

    network* {.
      desc: "The Eth2 network to build for (a known network name or a " &
            "directory containing config.yaml)"
      defaultValue: "mainnet"
      name: "network" .}: string

    beaconNodes* {.
      desc: "URL of a beacon node REST API to follow; may be repeated"
      defaultValueDesc: DefaultBeaconNode
      name: "beacon-node" .}: seq[string]

    builderPubkey* {.
      desc: "BLS public key of our builder, used to look up its index and " &
            "balance (optional in the M1 dry run)"
      name: "builder-pubkey" .}: Option[ValidatorPubKey]

func parseCmdArg*(
    T: type ValidatorPubKey, input: string): T {.raises: [ValueError].} =
  ValidatorPubKey.fromHex(input).valueOr:
    raise (ref ValueError)(msg: "Invalid BLS public key: " & $error)

func completeCmdArg*(T: type ValidatorPubKey, input: string): seq[string] =
  @[]

func beaconNodeUrls*(config: NimbuConf): seq[string] =
  if config.beaconNodes.len > 0:
    config.beaconNodes
  else:
    @[DefaultBeaconNode]
