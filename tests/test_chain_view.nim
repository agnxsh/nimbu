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
  ../nimbu/chain/chain_view

func root(i: byte): Eth2Digest =
  result.data[0] = i

func toRef[T](value: T): ref T =
  new result
  result[] = value

func prefs(
    slot: uint64, dependentRoot: Eth2Digest, validatorIndex = 7'u64,
    gasLimit = 60_000_000'u64): ref SignedProposerPreferences =
  toRef SignedProposerPreferences(message: ProposerPreferences(
    dependent_root: dependentRoot, proposal_slot: Slot(slot),
    validator_index: validatorIndex, target_gas_limit: gasLimit))

func bid(
    slot: uint64, value: uint64, builderIndex = 1'u64,
    parentHash = root(0xaa),
    parentRoot = root(0xbb)): ref gloas.SignedExecutionPayloadBid =
  toRef gloas.SignedExecutionPayloadBid(message: gloas.ExecutionPayloadBid(
    slot: Slot(slot), value: Gwei(value), builder_index: builderIndex,
    parent_block_hash: parentHash, parent_block_root: parentRoot,
    block_hash: root(byte(value mod 256))))

func head(
    slot: uint64, blockRoot: Eth2Digest, status = "empty",
    currentDep = root(0x01),
    nextDep = root(0x02)): ref HeadV2ChangeInfoObjectData =
  toRef HeadV2ChangeInfoObjectData(
    slot: Slot(slot), block_root: blockRoot, payload_status: status,
    current_epoch_dependent_root: currentDep,
    next_epoch_dependent_root: nextDep)

func attributes(
    proposalSlot: uint64, parentRoot: Eth2Digest, parentHash: Eth2Digest,
    proposerIndex = 7'u64): ref PayloadAttributesEventData =
  toRef PayloadAttributesEventData(
    proposer_index: proposerIndex, proposal_slot: Slot(proposalSlot),
    parent_block_root: parentRoot, parent_block_hash: parentHash)

suite "PrefsCache":
  test "first preferences for a (slot, dependent root) win":
    var cache = PrefsCache.init()
    check:
      cache.add(prefs(10, root(1), gasLimit = 30_000_000))
      not cache.add(prefs(10, root(1), gasLimit = 45_000_000))
      cache.get(Slot(10), root(1)).get.message.target_gas_limit == 30_000_000

  test "different dependent roots are different keys":
    var cache = PrefsCache.init()
    check:
      cache.add(prefs(10, root(1)))
      cache.add(prefs(10, root(2)))
      cache.len == 2
      cache.get(Slot(10), root(3)).isNone
      cache.hasSlot(Slot(10))
      not cache.hasSlot(Slot(11))

  test "prune drops older slots only":
    var cache = PrefsCache.init()
    discard cache.add(prefs(9, root(1)))
    discard cache.add(prefs(10, root(1)))
    cache.prune(Slot(10))
    check:
      cache.len == 1
      cache.get(Slot(9), root(1)).isNone
      cache.get(Slot(10), root(1)).isSome

  test "the cache shares the event's ref instead of copying it":
    var cache = PrefsCache.init()
    let p = prefs(10, root(1))
    discard cache.add(p)
    check cache.get(Slot(10), root(1)).get == p # same ref

  test "capacity bounds memory, least recently added entries go first":
    var cache = PrefsCache.init(capacity = 2)
    discard cache.add(prefs(10, root(1)))
    discard cache.add(prefs(11, root(1)))
    discard cache.add(prefs(12, root(1)))
    check:
      cache.len == 2
      cache.get(Slot(10), root(1)).isNone
      cache.get(Slot(12), root(1)).isSome

suite "BidObserver":
  test "tracks the best value per parent pair":
    var observer = BidObserver.init()
    check:
      observer.observe(bid(10, 100, builderIndex = 1))
      not observer.observe(bid(10, 100, builderIndex = 2)) # ties don't win
      not observer.observe(bid(10, 50, builderIndex = 3))
      observer.observe(bid(10, 150, builderIndex = 4))
    let best = observer.get(bid(10, 0).message.key).get
    check:
      best.value == Gwei(150)
      best.bid.message.builder_index == 4
      best.bidCount == 4

  test "the best bid is the event's own ref":
    var observer = BidObserver.init()
    let b = bid(10, 100)
    discard observer.observe(b)
    check observer.get(b.message.key).get.bid == b

  test "bestForSlot spans parent pairs":
    var observer = BidObserver.init()
    discard observer.observe(bid(10, 100, parentHash = root(1)))
    discard observer.observe(bid(10, 300, parentHash = root(2)))
    discard observer.observe(bid(11, 999))
    let best = observer.bestForSlot(Slot(10)).get
    check:
      best.value == Gwei(300)
      best.bid.message.parent_block_hash == root(2)
      observer.bestForSlot(Slot(12)).isNone

  test "prune drops older slots only":
    var observer = BidObserver.init()
    discard observer.observe(bid(9, 1))
    discard observer.observe(bid(10, 1))
    observer.prune(Slot(10))
    check:
      observer.len == 1
      observer.bestForSlot(Slot(9)).isNone

suite "HeadTracker":
  test "reports new heads and payload reveals":
    var tracker: HeadTracker
    check:
      tracker.update(head(10, root(1), "empty")) == HeadUpdate.NewHead
      tracker.update(head(10, root(1), "empty")) == HeadUpdate.Unchanged
      tracker.update(head(10, root(1), "full")) == HeadUpdate.PayloadRevealed
      tracker.head.get.payloadStatus == HeadPayloadStatus.Full
      tracker.update(head(11, root(2), "empty")) == HeadUpdate.NewHead

  test "unknown payload status strings are tolerated":
    check:
      parsePayloadStatus("full") == HeadPayloadStatus.Full
      parsePayloadStatus("empty") == HeadPayloadStatus.Empty
      parsePayloadStatus("pending") == HeadPayloadStatus.Unknown

  test "dependent roots cover the head's epoch and the next":
    let view = HeadView.init(head(
      SLOTS_PER_EPOCH + 3, root(1), currentDep = root(0xc), nextDep = root(0xd)))
    check:
      view.dependentRootFor(Epoch(1)).get == root(0xc)
      view.dependentRootFor(Epoch(2)).get == root(0xd)
      view.dependentRootFor(Epoch(0)).isNone
      view.dependentRootFor(Epoch(3)).isNone

suite "ChainView":
  test "build opportunity resolves proposer preferences via the head":
    let view = ChainViewRef.new()
    check:
      view.apply(ChainEventRef(
        kind: ChainEventKind.Head,
        head: head(10, root(0x10), nextDep = root(0xd)))) ==
          ApplyResult.NewHead
      view.apply(ChainEventRef(
        kind: ChainEventKind.PayloadAttributes,
        attributes: attributes(11, root(0x10), root(0xaa)))) ==
          ApplyResult.NewOpportunity
    # Slot 11 is still epoch 0 with SLOTS_PER_EPOCH = 32: current dependent root
    var summary = view.summarize(Slot(11))
    check:
      summary.opportunities == 1
      summary.opportunitiesWithPrefs == 0

    discard view.apply(ChainEventRef(
      kind: ChainEventKind.ProposerPreferences, preferences: prefs(11, root(1))))
    summary = view.summarize(Slot(11))
    check summary.opportunitiesWithPrefs == 1

  test "preferences for another proposer are not matched":
    let view = ChainViewRef.new()
    discard view.apply(ChainEventRef(
      kind: ChainEventKind.Head, head: head(10, root(0x10))))
    discard view.apply(ChainEventRef(
      kind: ChainEventKind.PayloadAttributes,
      attributes: attributes(11, root(0x10), root(0xaa), proposerIndex = 8)))
    discard view.apply(ChainEventRef(
      kind: ChainEventKind.ProposerPreferences,
      preferences: prefs(11, root(1), validatorIndex = 7)))
    check view.summarize(Slot(11)).opportunitiesWithPrefs == 0

  test "attributes arriving before their head are resolved later":
    let view = ChainViewRef.new()
    discard view.apply(ChainEventRef(
      kind: ChainEventKind.PayloadAttributes,
      attributes: attributes(11, root(0x10), root(0xaa))))
    discard view.apply(ChainEventRef(
      kind: ChainEventKind.ProposerPreferences, preferences: prefs(11, root(1))))
    check view.summarize(Slot(11)).opportunitiesWithPrefs == 0
    discard view.apply(ChainEventRef(
      kind: ChainEventKind.Head, head: head(10, root(0x10))))
    check view.summarize(Slot(11)).opportunitiesWithPrefs == 1

  test "EMPTY and FULL parents are separate opportunities":
    let view = ChainViewRef.new()
    check:
      view.apply(ChainEventRef(
        kind: ChainEventKind.PayloadAttributes,
        attributes: attributes(11, root(0x10), root(0xaa)))) ==
          ApplyResult.NewOpportunity
      view.apply(ChainEventRef(
        kind: ChainEventKind.PayloadAttributes,
        attributes: attributes(11, root(0x10), root(0xab)))) ==
          ApplyResult.NewOpportunity
      view.apply(ChainEventRef(
        kind: ChainEventKind.PayloadAttributes,
        attributes: attributes(11, root(0x10), root(0xab)))) ==
          ApplyResult.Ignored
      view.opportunitiesFor(Slot(11)).len == 2

  test "best bid and finality are tracked; prune forgets old slots":
    let view = ChainViewRef.new()
    check:
      view.apply(ChainEventRef(
        kind: ChainEventKind.ExecutionPayloadBid,
        bid: bid(11, 500))) ==
          ApplyResult.NewBestBid
      view.apply(ChainEventRef(
        kind: ChainEventKind.FinalizedCheckpoint,
        finalized: FinalizationInfoObject(epoch: Epoch(3)))) ==
          ApplyResult.Updated
      view.summarize(Slot(11)).bestBid.get.value == Gwei(500)
      view.heads.finalizedEpoch == Epoch(3)
    view.prune(Slot(12))
    check view.summarize(Slot(11)).bestBid.isNone
