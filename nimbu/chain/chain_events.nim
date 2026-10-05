# nimbu
# Copyright (c) 2026 Agnish Ghosh
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

## Typed beacon node SSE events that nimbu consumes - see
## notes/0002-gloas-spec-digest.md §7

import
  results,
  beacon_chain/spec/eth2_apis/[eth2_rest_serialization, rest_types],
  beacon_chain/consensus_object_pools/block_pools_types

export
  results, rest_types, block_pools_types

type
  # Wire formats of the versioned events. Large or shared payloads are
  # decoded straight into `ref` fields so they are allocated once and shared,
  # never copied, by the caches downstream; small transient ones stay values
  # (notes/0006-coding-standards.md §6).
  HeadV2Event = object
    version: string
    data: ref HeadV2ChangeInfoObjectData

  PayloadAttributesEvent = object
    version: string
    data: ref PayloadAttributesEventData

  ProposerPreferencesEvent = object
    version: string
    data: ref SignedProposerPreferences

  ExecutionPayloadBidEvent = object
    version: string
    data: ref gloas.SignedExecutionPayloadBid

  ChainEventKind* {.pure.} = enum
    Head
    PayloadAttributes
    ProposerPreferences
    ExecutionPayloadBid
    ExecutionPayloadAvailable
    ChainReorg
    FinalizedCheckpoint

  ChainEventRef* = ref object
    case kind*: ChainEventKind
    of ChainEventKind.Head:
      head*: ref HeadV2ChangeInfoObjectData
    of ChainEventKind.PayloadAttributes:
      attributes*: ref PayloadAttributesEventData
    of ChainEventKind.ProposerPreferences:
      preferences*: ref SignedProposerPreferences
    of ChainEventKind.ExecutionPayloadBid:
      bid*: ref gloas.SignedExecutionPayloadBid
    of ChainEventKind.ExecutionPayloadAvailable:
      available*: EventExecutionPayloadAvailableObject
    of ChainEventKind.ChainReorg:
      reorg*: ReorgInfoObject
    of ChainEventKind.FinalizedCheckpoint:
      finalized*: FinalizationInfoObject

const
  ChainEventTopics*: EventTopics = {
    EventTopic.HeadV2, EventTopic.PayloadAttributes,
    EventTopic.ProposerPreferences, EventTopic.ExecutionPayloadBid,
    EventTopic.ExecutionPayloadAvailable, EventTopic.ChainReorg,
    EventTopic.FinalizedCheckpoint}

RestJson.useDefaultSerializationFor(
  HeadV2Event, PayloadAttributesEvent, ProposerPreferencesEvent,
  ExecutionPayloadBidEvent)

proc decodeJson[T](data: string, _: typedesc[T]): Result[T, string] =
  try:
    ok RestJson.decode(data, T)
  except SerializationError as exc:
    err exc.formatMsg("<data>")

proc decodeChainEvent*(
    topic, data: string): Result[Opt[ChainEventRef], string] =
  ## Decodes the `data` of an SSE event with the given `event` topic name.
  ## Topics nimbu does not consume decode to `none`.
  template decoded(T: typedesc, event: untyped): untyped =
    let it {.inject.} = decodeJson(data, T).valueOr:
      return err(topic & ": " & error)
    ok Opt.some(event)

  template decodedVersioned(T: typedesc, event: untyped): untyped =
    let wire = decodeJson(data, T).valueOr:
      return err(topic & ": " & error)
    let it {.inject.} = wire.data
    if it.isNil:
      return err(topic & ": null payload")
    ok Opt.some(event)

  case topic
  of "head_v2":
    decodedVersioned(HeadV2Event,
      ChainEventRef(kind: ChainEventKind.Head, head: it))
  of "payload_attributes":
    decodedVersioned(PayloadAttributesEvent,
      ChainEventRef(kind: ChainEventKind.PayloadAttributes, attributes: it))
  of "proposer_preferences":
    decodedVersioned(ProposerPreferencesEvent,
      ChainEventRef(kind: ChainEventKind.ProposerPreferences, preferences: it))
  of "execution_payload_bid":
    decodedVersioned(ExecutionPayloadBidEvent,
      ChainEventRef(kind: ChainEventKind.ExecutionPayloadBid, bid: it))
  of "execution_payload_available":
    decoded(EventExecutionPayloadAvailableObject,
      ChainEventRef(kind: ChainEventKind.ExecutionPayloadAvailable,
                    available: it))
  of "chain_reorg":
    decoded(ReorgInfoObject,
      ChainEventRef(kind: ChainEventKind.ChainReorg, reorg: it))
  of "finalized_checkpoint":
    decoded(FinalizationInfoObject,
      ChainEventRef(kind: ChainEventKind.FinalizedCheckpoint, finalized: it))
  else:
    ok Opt.none(ChainEventRef)
