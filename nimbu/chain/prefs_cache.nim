# nimbu
# Copyright (c) 2026 Agnish Ghosh
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

## Cache of `SignedProposerPreferences` seen on the beacon node's event
## stream - see notes/0001-architecture-flow.md §3.1
##
## Mirrors the gossip `Seen` rule: the first preferences for a
## `(proposal_slot, dependent_root)` pair win, later ones are ignored.
## The beacon node only emits preferences that passed gossip validation, so
## signatures are not re-verified here. Entries are shared refs, never copies.

import
  minilru, results,
  beacon_chain/spec/datatypes/gloas

export results, gloas

const
  DefaultPrefsCacheCapacity* = 4 * SLOTS_PER_EPOCH.int
    ## Proposers publish preferences for the current epoch and up to
    ## `MIN_SEED_LOOKAHEAD` ahead; the margin covers competing dependent roots

type
  PrefsKey* = tuple[slot: Slot, dependentRoot: Eth2Digest]

  PrefsCache* = object
    entries: minilru.LruCache[PrefsKey, ref SignedProposerPreferences]

func init*(
    T: type PrefsCache, capacity = DefaultPrefsCacheCapacity): PrefsCache =
  PrefsCache(entries:
    minilru.LruCache[PrefsKey, ref SignedProposerPreferences].init(capacity))

func len*(cache: PrefsCache): int =
  cache.entries.len

func add*(cache: var PrefsCache, prefs: ref SignedProposerPreferences): bool =
  ## Returns `true` when `prefs` is the first seen for its key
  let key: PrefsKey =
    (prefs[].message.proposal_slot, prefs[].message.dependent_root)
  if key in cache.entries:
    return false
  cache.entries.put(key, prefs)
  true

func get*(
    cache: PrefsCache, slot: Slot,
    dependentRoot: Eth2Digest): Opt[ref SignedProposerPreferences] =
  cache.entries.peek((slot, dependentRoot))

func hasSlot*(cache: PrefsCache, slot: Slot): bool =
  ## Whether any preferences are known for `slot`, under any dependent root
  for key in cache.entries.keys:
    if key.slot == slot:
      return true
  false

func prune*(cache: var PrefsCache, oldestSlot: Slot) =
  ## Drops preferences for slots before `oldestSlot`
  var stale: seq[PrefsKey]
  for key in cache.entries.keys:
    if key.slot < oldestSlot:
      stale.add key
  for key in stale:
    cache.entries.del key
