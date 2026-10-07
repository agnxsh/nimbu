# nimbu
# Copyright (c) 2026 Agnish Ghosh
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

## nimbu - external Gloas (EIP-7732 / ePBS) payload builder
##
## M1: follows the beacon chain and logs what a builder would see, without
## building, signing or sending anything - see
## notes/0001-architecture-flow.md §10

import
  std/posix,
  chronos, chronicles,
  beacon_chain/buildinfo,
  beacon_chain/networking/network_metadata,
  beacon_chain/spec/datatypes/base,
  ./chain/chain_follower,
  ./[conf, version]

logScope: topics = "nimbu"

proc writeStderr(msg: string) =
  try:
    stderr.writeLine(msg)
  except IOError:
    discard # nowhere left to report it

proc loadConfig(): Result[NimbuConf, string] =
  let versionBanner =
    "nimbu " & fullVersionStr & "\p" & copyrights & "\p\p" & nimFullBanner
  # `load` must not be expanded inside `ok(...)`: confutils generates procs
  # that would then be inferred `noSideEffect` and fail to type-check
  let config =
    try:
      NimbuConf.load(version = versionBanner, copyrightBanner = nimbuAgentStr)
    except CatchableError as exc:
      return err(exc.msg)
  ok(config)

proc waitForShutdown() {.async: (raises: [CancelledError]).} =
  try:
    discard await race(waitSignal(SIGINT), waitSignal(SIGTERM))
  except AsyncError as exc:
    fatal "Unable to install signal handlers", reason = exc.msg
    quit QuitFailure

proc run(config: NimbuConf, cfg: RuntimeConfig) {.
    async: (raises: [CancelledError]).} =
  let urls = config.beaconNodeUrls().valueOr:
    fatal "Invalid configuration", reason = error
    quit QuitFailure
  let follower = ChainFollowerRef.new(
    cfg, urls,
    if config.builderPubkey.isSome:
      Opt.some(config.builderPubkey.get)
    else:
      Opt.none(ValidatorPubKey)).valueOr:
    fatal "Invalid configuration", reason = error
    quit QuitFailure

  (await follower.start()).isOkOr:
    fatal "Unable to follow the beacon chain", reason = error
    quit QuitFailure

  await waitForShutdown()
  notice "Shutting down"
  await follower.stop()

proc main() =
  let config = loadConfig().valueOr:
    writeStderr("Failure while loading the configuration:\p" & error)
    quit QuitFailure

  setupLogging(config.logLevel, config.logFormat).isOkOr:
    writeStderr(error)
    quit QuitFailure

  let metadata = getMetadataForNetwork(config.network)

  notice "🍋 Starting nimbu",
    version = fullVersionStr,
    specVersion = SPEC_VERSION,
    constPreset = const_preset,
    network = config.network,
    configName = metadata.cfg.CONFIG_NAME,
    gloasForkEpoch = metadata.cfg.GLOAS_FORK_EPOCH,
    mode = "dry-run"

  try:
    waitFor run(config, metadata.cfg)
  except CancelledError:
    discard

when isMainModule:
  main()
