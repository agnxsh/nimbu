# nimbu
# Copyright (c) 2026 Agnish Ghosh
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

## The beacon node's head as seen through `head_v2` events, including whether
## the head block's payload has been revealed - see
## notes/0002-gloas-spec-digest.md §4

import
  results,
  beacon_chain/spec/datatypes/gloas,
  beacon_chain/consensus_object_pools/block_pools_types

export results, gloas

type
  HeadPayloadStatus* {.pure.} = enum
    Unknown
    Empty
    Full

  HeadView* = object
    data*: ref HeadV2ChangeInfoObjectData
      ## Shared with the `head_v2` event that carried it
    payloadStatus*: HeadPayloadStatus

  HeadUpdate* {.pure.} = enum
    Unchanged
    NewHead
    PayloadRevealed
      ## Same head block, payload status went from empty to full

  HeadTracker* = object
    head*: Opt[HeadView]
    finalizedEpoch*: Epoch
    reorgs*: uint64

func parsePayloadStatus*(value: string): HeadPayloadStatus =
  case value
  of "empty": HeadPayloadStatus.Empty
  of "full": HeadPayloadStatus.Full
  else: HeadPayloadStatus.Unknown

func init*(
    T: type HeadView, data: ref HeadV2ChangeInfoObjectData): HeadView =
  HeadView(
    data: data, payloadStatus: parsePayloadStatus(data[].payload_status))

template slot*(head: HeadView): Slot = head.data[].slot
template root*(head: HeadView): Eth2Digest = head.data[].block_root

func update*(
    tracker: var HeadTracker,
    data: ref HeadV2ChangeInfoObjectData): HeadUpdate =
  let
    view = HeadView.init(data)
    prev = tracker.head.valueOr:
      tracker.head = Opt.some(view)
      return HeadUpdate.NewHead
  if prev.data[] == data[]:
    return HeadUpdate.Unchanged
  tracker.head = Opt.some(view)
  if prev.root == view.root and
      prev.payloadStatus != HeadPayloadStatus.Full and
      view.payloadStatus == HeadPayloadStatus.Full:
    return HeadUpdate.PayloadRevealed
  HeadUpdate.NewHead

func dependentRootFor*(head: HeadView, epoch: Epoch): Opt[Eth2Digest] =
  ## Proposer shuffling dependent root for `epoch` on the head's chain, as
  ## defined for `head_v2` in beacon-APIs; only the head's epoch and the
  ## next one are known
  if epoch == head.slot.epoch:
    Opt.some(head.data[].current_epoch_dependent_root)
  elif epoch == head.slot.epoch + 1:
    Opt.some(head.data[].next_epoch_dependent_root)
  else:
    Opt.none(Eth2Digest)
