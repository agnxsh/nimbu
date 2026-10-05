# nimbu
# Copyright (c) 2026 Agnish Ghosh
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}
{.used.}

## Decodes the beacon-APIs example events (tests/fixtures/events)

import
  std/[os, strutils],
  unittest2,
  ../nimbu/chain/chain_events

const fixturesDir = currentSourcePath.parentDir / "fixtures" / "events"

proc fixture(topic: string): string =
  try:
    readFile(fixturesDir / topic & ".json").strip()
  except IOError as exc:
    raiseAssert "missing fixture " & topic & ": " & exc.msg

proc decodeFixture(topic: string): ChainEventRef =
  let res = decodeChainEvent(topic, fixture(topic))
  check res.isOk()
  let ev = res.get()
  check ev.isSome()
  ev.get()

suite "SSE event decoding (beacon-APIs examples)":
  test "head_v2":
    let ev = decodeFixture("head_v2")
    check:
      ev.kind == ChainEventKind.Head
      ev.head.slot == Slot(10)
      ev.head.payload_status == "empty"
      ev.head.block_root == Eth2Digest.fromHex(
        "0x9a2fefd2fdb57f74993c7780ea5b9030d2897b615b89f808011ca5aebed54eaf")
      ev.head.current_epoch_dependent_root == Eth2Digest.fromHex(
        "0x5e0043f107cb57913498fbf2f99ff55e730bf1e151f02f221e977c91a90a0e91")

  test "payload_attributes (Gloas)":
    let ev = decodeFixture("payload_attributes")
    check:
      ev.kind == ChainEventKind.PayloadAttributes
      ev.attributes.proposer_index == 123
      ev.attributes.proposal_slot == Slot(10)
      ev.attributes.parent_block_hash == Eth2Digest.fromHex(
        "0x9a2fefd2fdb57f74993c7780ea5b9030d2897b615b89f808011ca5aebed54eaf")
      ev.attributes.payload_attributes.withdrawals.len == 1
      ev.attributes.payload_attributes.withdrawals[0].amount == Gwei(15640)
      ev.attributes.payload_attributes.slot_number == 10
      ev.attributes.payload_attributes.target_gas_limit == 60_000_000

  test "proposer_preferences":
    let ev = decodeFixture("proposer_preferences")
    check:
      ev.kind == ChainEventKind.ProposerPreferences
      ev.preferences.message.proposal_slot == Slot(32)
      ev.preferences.message.validator_index == 123
      ev.preferences.message.target_gas_limit == 60_000_000

  test "execution_payload_bid":
    let ev = decodeFixture("execution_payload_bid")
    check:
      ev.kind == ChainEventKind.ExecutionPayloadBid
      ev.bid.message.builder_index == 42
      ev.bid.message.slot == Slot(10)
      ev.bid.message.value == Gwei(1_000_000_000)
      ev.bid.message.execution_payment == Gwei(0)
      ev.bid.message.gas_limit == 30_000_000
      ev.bid.message.blob_kzg_commitments.len == 1

  test "execution_payload_available":
    let ev = decodeFixture("execution_payload_available")
    check:
      ev.kind == ChainEventKind.ExecutionPayloadAvailable
      ev.available.slot == Slot(10)

  test "chain_reorg (unknown `epoch` field is tolerated)":
    let ev = decodeFixture("chain_reorg")
    check:
      ev.kind == ChainEventKind.ChainReorg
      ev.reorg.slot == Slot(200)
      ev.reorg.depth == 50

  test "finalized_checkpoint":
    let ev = decodeFixture("finalized_checkpoint")
    check:
      ev.kind == ChainEventKind.FinalizedCheckpoint
      ev.finalized.epoch == Epoch(2)

  test "topics nimbu does not consume decode to none":
    let res = decodeChainEvent("block", fixture("block"))
    check:
      res.isOk()
      res.get().isNone()

  test "malformed payloads are reported, not raised":
    let res = decodeChainEvent("head_v2", """{"version": "gloas"}""")
    check:
      res.isErr()
      res.error.startsWith("head_v2: ")
