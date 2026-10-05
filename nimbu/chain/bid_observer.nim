# nimbu
# Copyright (c) 2026 Agnish Ghosh
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

## Tracks the best competing `execution_payload_bid` per
## `(slot, parent_block_hash, parent_block_root)` - the same key gossip uses
## for its "best bid seen" rule, see notes/0002-gloas-spec-digest.md §5

import
  minilru, results,
  beacon_chain/spec/datatypes/gloas

export results, gloas

const
  DefaultBidObserverCapacity* = 4 * SLOTS_PER_EPOCH.int
    ## A handful of parent pairs per slot, for a few slots

type
  BidKey* = tuple[
    slot: Slot, parentBlockHash: Eth2Digest, parentBlockRoot: Eth2Digest]

  BestBid* = object
    bid*: ref gloas.SignedExecutionPayloadBid
      ## The best bid itself, shared with the event that carried it
    bidCount*: int
      ## Bids observed for this key, including those that were not the best

  BidObserver* = object
    best: minilru.LruCache[BidKey, BestBid]

func init*(
    T: type BidObserver, capacity = DefaultBidObserverCapacity): BidObserver =
  BidObserver(best: minilru.LruCache[BidKey, BestBid].init(capacity))

func key*(bid: gloas.ExecutionPayloadBid): BidKey =
  (bid.slot, bid.parent_block_hash, bid.parent_block_root)

template value*(best: BestBid): Gwei =
  best.bid[].message.value

func len*(observer: BidObserver): int =
  observer.best.len

func observe*(
    observer: var BidObserver,
    bid: ref gloas.SignedExecutionPayloadBid): bool =
  ## Records `bid`; returns `true` when it is the new best for its key
  let key = bid[].message.key
  var best = observer.best.peek(key).valueOr:
    observer.best.put(key, BestBid(bid: bid, bidCount: 1))
    return true
  inc best.bidCount
  let isBest = bid[].message.value > best.value
  if isBest:
    best.bid = bid
  discard observer.best.update(key, best)
  isBest

func get*(observer: BidObserver, key: BidKey): Opt[BestBid] =
  observer.best.peek(key)

func bestForSlot*(observer: BidObserver, slot: Slot): Opt[BestBid] =
  ## The highest bid for `slot` across all parent pairs
  var res: Opt[BestBid]
  for (key, best) in observer.best.pairs:
    if key.slot == slot and (res.isNone or best.value > res.get.value):
      res = Opt.some(best)
  res

func prune*(observer: var BidObserver, oldestSlot: Slot) =
  ## Drops bids for slots before `oldestSlot`
  var stale: seq[BidKey]
  for key in observer.best.keys:
    if key.slot < oldestSlot:
      stale.add key
  for key in stale:
    observer.best.del key
