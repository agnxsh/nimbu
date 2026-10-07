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

  PublicBeaconNodes* = [
    ## Public beacon nodes run by ethpandaops, for `--public-beacon-node`
    ("sepolia", "https://beacon.sepolia.ethpandaops.io"),
    ("plataberget", "https://beacon.glamsterdam-devnet-8.ethpandaops.io"),
  ]

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

    publicBeaconNode* {.
      desc: "Also follow the public ethpandaops beacon node of --network " &
            "(sepolia, plataberget)"
      defaultValue: false
      name: "public-beacon-node" .}: bool

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

func publicBeaconNodeFor*(network: string): Opt[string] =
  for (name, url) in PublicBeaconNodes:
    if name == network:
      return Opt.some(url)
  Opt.none(string)

func beaconNodeUrls*(config: NimbuConf): Result[seq[string], string] =
  var urls = config.beaconNodes
  if config.publicBeaconNode:
    let url = publicBeaconNodeFor(config.network).valueOr:
      return err("No known public beacon node for network '" &
        config.network & "'; pass --beacon-node instead")
    if url notin urls:
      urls.add url
  if urls.len == 0:
    urls.add DefaultBeaconNode
  ok urls
