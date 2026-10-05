# nimbu
# Copyright (c) 2026 Agnish Ghosh
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

## Pure, event-driven view of the chain from a builder's perspective.
## `ChainFollower` feeds it events; nothing here does I/O - see
## notes/0001-architecture-flow.md §3.1-3.2
##
## Large decoded payloads are shared by ref between the event and every
## cache that keeps them; small bookkeeping stays in values
## (notes/0006-coding-standards.md §6).

import
  std/algorithm,
  minilru,
  ./[bid_observer, chain_events, head_tracker, prefs_cache]

export bid_observer, chain_events, head_tracker, prefs_cache

const
  DefaultOpportunitiesCapacity* = 2 * SLOTS_PER_EPOCH.int
    ## Typically one EMPTY and one FULL parent per upcoming slot

type
  BuildOpportunity* = object
    ## A `payload_attributes` event: the beacon node expects a payload for
    ## `proposal_slot` on top of this parent pair. Becomes a `BuildJob` in M2.
    attributes*: ref PayloadAttributesEventData
      ## Shared with the event that carried it
    dependentRoot*: Opt[Eth2Digest]
      ## Resolved from the head when the parent is the head; `none` otherwise

  ChainViewRef* = ref object
    heads*: HeadTracker
    prefs*: PrefsCache
    bids*: BidObserver
    opportunities: minilru.LruCache[BidKey, BuildOpportunity]

  SlotSummary* = object
    slot*: Slot
    head*: Opt[HeadView]
    opportunities*: int
    opportunitiesWithPrefs*: int
    bestBid*: Opt[BestBid]

  ApplyResult* {.pure.} = enum
    Ignored
    Updated
    NewHead
    PayloadRevealed
    NewOpportunity
    NewBestBid

func new*(T: type ChainViewRef): ChainViewRef =
  ChainViewRef(
    prefs: PrefsCache.init(),
    bids: BidObserver.init(),
    opportunities: minilru.LruCache[BidKey, BuildOpportunity].init(
      DefaultOpportunitiesCapacity))

template proposalSlot*(opp: BuildOpportunity): Slot =
  opp.attributes[].proposal_slot

template proposerIndex*(opp: BuildOpportunity): uint64 =
  opp.attributes[].proposer_index

template parentBlockRoot*(opp: BuildOpportunity): Eth2Digest =
  opp.attributes[].parent_block_root

template parentBlockHash*(opp: BuildOpportunity): Eth2Digest =
  opp.attributes[].parent_block_hash

func key*(opp: BuildOpportunity): BidKey =
  (opp.proposalSlot, opp.parentBlockHash, opp.parentBlockRoot)

func dependentRootFromHead(
    view: ChainViewRef, parentBlockRoot: Eth2Digest,
    proposalSlot: Slot): Opt[Eth2Digest] =
  let head = view.heads.head.valueOr:
    return Opt.none(Eth2Digest)
  if head.root != parentBlockRoot:
    return Opt.none(Eth2Digest)
  head.dependentRootFor(proposalSlot.epoch)

func preferencesFor*(
    view: ChainViewRef,
    opp: BuildOpportunity): Opt[ref SignedProposerPreferences] =
  ## The proposer's preferences for this opportunity; without them the
  ## proposer accepts no trustless bids for the slot
  let dependentRoot = opp.dependentRoot.valueOr:
    # The attributes may have arrived before the matching head event
    view.dependentRootFromHead(opp.parentBlockRoot, opp.proposalSlot).valueOr:
      return Opt.none(ref SignedProposerPreferences)
  let prefs = view.prefs.get(opp.proposalSlot, dependentRoot).valueOr:
    return Opt.none(ref SignedProposerPreferences)
  if prefs[].message.validator_index != opp.proposerIndex:
    # Mismatch means our dependent root resolution is wrong for this branch
    return Opt.none(ref SignedProposerPreferences)
  Opt.some(prefs)

func opportunitiesFor*(
    view: ChainViewRef, slot: Slot): seq[BuildOpportunity] =
  for opp in view.opportunities.values:
    if opp.proposalSlot == slot:
      result.add opp
  result.sort(proc(a, b: BuildOpportunity): int =
    cmp($a.parentBlockHash, $b.parentBlockHash))

func apply*(view: ChainViewRef, event: ChainEventRef): ApplyResult =
  case event.kind
  of ChainEventKind.Head:
    case view.heads.update(event.head)
    of HeadUpdate.Unchanged: ApplyResult.Ignored
    of HeadUpdate.NewHead: ApplyResult.NewHead
    of HeadUpdate.PayloadRevealed: ApplyResult.PayloadRevealed
  of ChainEventKind.PayloadAttributes:
    let data = event.attributes
    let opp = BuildOpportunity(
      attributes: data,
      dependentRoot: view.dependentRootFromHead(
        data[].parent_block_root, data[].proposal_slot))
    if opp.key in view.opportunities:
      ApplyResult.Ignored
    else:
      view.opportunities.put(opp.key, opp)
      ApplyResult.NewOpportunity
  of ChainEventKind.ProposerPreferences:
    if view.prefs.add(event.preferences):
      ApplyResult.Updated
    else:
      ApplyResult.Ignored
  of ChainEventKind.ExecutionPayloadBid:
    if view.bids.observe(event.bid):
      ApplyResult.NewBestBid
    else:
      ApplyResult.Ignored
  of ChainEventKind.ExecutionPayloadAvailable:
    ApplyResult.Ignored
  of ChainEventKind.ChainReorg:
    inc view.heads.reorgs
    ApplyResult.Updated
  of ChainEventKind.FinalizedCheckpoint:
    if event.finalized.epoch > view.heads.finalizedEpoch:
      view.heads.finalizedEpoch = event.finalized.epoch
      ApplyResult.Updated
    else:
      ApplyResult.Ignored

func summarize*(view: ChainViewRef, slot: Slot): SlotSummary =
  result = SlotSummary(
    slot: slot, head: view.heads.head, bestBid: view.bids.bestForSlot(slot))
  for opp in view.opportunitiesFor(slot):
    inc result.opportunities
    if view.preferencesFor(opp).isSome:
      inc result.opportunitiesWithPrefs

func prune*(view: ChainViewRef, oldestSlot: Slot) =
  ## Forgets everything about slots before `oldestSlot`
  view.prefs.prune(oldestSlot)
  view.bids.prune(oldestSlot)
  var stale: seq[BidKey]
  for key in view.opportunities.keys:
    if key.slot < oldestSlot:
      stale.add key
  for key in stale:
    view.opportunities.del key
