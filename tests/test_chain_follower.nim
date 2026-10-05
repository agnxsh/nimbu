# nimbu
# Copyright (c) 2026 Agnish Ghosh
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}
{.used.}

## ChainFollower and BuilderView against a mock beacon node that replays the
## beacon-APIs example events (tests/fixtures/events) over SSE

import
  std/[os, strutils],
  unittest2, chronos/unittest2/asynctests,
  stew/byteutils,
  beacon_chain/spec/presets,
  ../nimbu/chain/chain_follower,
  ./mocks/mock_beacon_node

const
  fixturesDir = currentSourcePath.parentDir / "fixtures" / "events"
  secretHex =
    "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f"

proc fixture(topic: string): string =
  try:
    readFile(fixturesDir / topic & ".json").strip()
  except IOError as exc:
    raiseAssert "missing fixture " & topic & ": " & exc.msg

proc genesisJson(forkVersion = "0x00000000"): string =
  """{"data": {"genesis_time": "1606824023", """ &
  """"genesis_validators_root": """ &
  """"0x4b363db94e286120d76eb905340fdd4e54bfe9f06bf33ff6cf5ad27f511bfe95", """ &
  """"genesis_fork_version": """" & forkVersion & """"}}"""

func ourPubkey(): ValidatorPubKey =
  const secret = hexToSeqByte(secretHex)
  ValidatorPrivKey.fromRaw(secret).get().toPubKey().toPubKey()

func ourPubkeyHex(): string =
  "0x" & ourPubkey().blob.toHex()

proc buildersJson(pubkeyHex: string): string =
  """{"execution_optimistic": false, "finalized": false, "data": [""" &
  """{"index": "5", "status": "active", "builder": {""" &
  """"pubkey": """" & pubkeyHex & """", "version": "0", """ &
  """"execution_address": "0x0000000000000000000000000000000000000001", """ &
  """"balance": "64000000000", "deposit_epoch": "1", """ &
  """"withdrawable_epoch": "18446744073709551615"}}]}"""

proc waitUntil(
    cond: proc(): bool {.gcsafe, raises: [].},
    timeout = 5.seconds): Future[bool] {.async: (raises: [CancelledError]).} =
  let deadline = Moment.now() + timeout
  while Moment.now() < deadline:
    if cond():
      return true
    await sleepAsync(20.milliseconds)
  cond()

suite "BuilderView responses":
  test "a matching builder is found and shares the decoded record":
    let view = BuilderViewRef.new(ourPubkey())
    view.applyResponse(RestPlainResponse(
      status: 200, data: buildersJson(ourPubkeyHex()).toBytes()), Slot(1))
    check:
      view.lookup == BuilderLookup.Found
      view.info.get.index == 5
      view.info.get.status == "active"
      view.info.get.builder.balance == Gwei(64_000_000_000'u64)
      view.lastRefresh == Opt.some(Slot(1))

  test "an empty result means the builder is not registered":
    let view = BuilderViewRef.new(ourPubkey())
    view.applyResponse(RestPlainResponse(
      status: 200,
      data: """{"execution_optimistic": false, "finalized": false, "data": []}"""
        .toBytes()), Slot(1))
    check:
      view.lookup == BuilderLookup.NotRegistered
      view.info.isNone

  test "an unknown route means the endpoint is unsupported":
    let view = BuilderViewRef.new(ourPubkey())
    view.applyResponse(RestPlainResponse(
      status: 404, data: """{"code": 404, "message": "Route not found"}"""
        .toBytes()), Slot(1))
    check:
      view.lookup == BuilderLookup.Unsupported
      view.lastError == "Route not found"

  test "a missing state is a transient failure, not unsupported":
    let view = BuilderViewRef.new(ourPubkey())
    view.applyResponse(RestPlainResponse(
      status: 404, data: """{"code": 404, "message": "State not found"}"""
        .toBytes()), Slot(1))
    check view.lookup == BuilderLookup.Unknown

  test "the request asks for our public key":
    check BuilderViewRef.new(ourPubkey()).request().ids == @[ourPubkeyHex()]

suite "ChainFollower against a mock beacon node":
  asyncTest "follows events into the chain view":
    let mock = MockBeaconNodeRef.new().get()
    mock.genesisJson = genesisJson()
    for topic in ["head_v2", "payload_attributes", "proposer_preferences",
                  "execution_payload_bid", "block", "chain_reorg",
                  "finalized_checkpoint"]:
      mock.events.add((topic, fixture(topic)))

    let follower = ChainFollowerRef.new(
      defaultRuntimeConfig, [mock.url], Opt.none(ValidatorPubKey)).get()
    check (await follower.start()).isOk()

    let node = follower.nodes[0]
    check await waitUntil(proc(): bool =
      node.eventsReceived >= mock.events.len.uint64)

    let view = follower.view
    check:
      node.decodeErrors == 0
      follower.genesisValidatorsRoot == Eth2Digest.fromHex(
        "0x4b363db94e286120d76eb905340fdd4e54bfe9f06bf33ff6cf5ad27f511bfe95")
      view.heads.head.get.slot == Slot(10)
      view.heads.head.get.payloadStatus == HeadPayloadStatus.Empty
      view.heads.finalizedEpoch == Epoch(2)
      view.heads.reorgs >= 1
      view.opportunitiesFor(Slot(10)).len == 1
      view.prefs.get(Slot(32), Eth2Digest.fromHex(
        "0xcf8e0d4e9587369b2301d0790347320302cc0943d5a1884560367e8208d920f2"))
          .isSome
      view.bids.bestForSlot(Slot(10)).get.value == Gwei(1_000_000_000)

    await follower.stop()
    await mock.closeWait()

  asyncTest "refreshes our builder record":
    let mock = MockBeaconNodeRef.new().get()
    mock.genesisJson = genesisJson()
    mock.buildersJson = buildersJson(ourPubkeyHex())

    let follower = ChainFollowerRef.new(
      defaultRuntimeConfig, [mock.url], Opt.some(ourPubkey())).get()
    let builder = follower.builder.get
    await builder.refresh(follower.nodes[0].client, Slot(100))
    check:
      mock.buildersRequests == 1
      ourPubkeyHex() in mock.lastBuildersBody
      builder.lookup == BuilderLookup.Found
      builder.info.get.index == 5

    await follower.stop()
    await mock.closeWait()

  asyncTest "refuses a beacon node on another network":
    let mock = MockBeaconNodeRef.new().get()
    mock.genesisJson = genesisJson(forkVersion = "0x10000038")

    let follower = ChainFollowerRef.new(
      defaultRuntimeConfig, [mock.url], Opt.none(ValidatorPubKey)).get()
    let res = await follower.start()
    check:
      res.isErr()
      "different network" in res.error

    await follower.stop()
    await mock.closeWait()

  test "rejects invalid configuration":
    check:
      ChainFollowerRef.new(
        defaultRuntimeConfig, [], Opt.none(ValidatorPubKey)).isErr()
      ChainFollowerRef.new(
        defaultRuntimeConfig, ["not a url"], Opt.none(ValidatorPubKey)).isErr()
