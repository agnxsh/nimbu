# nimbu
# Copyright (c) 2026 Agnish Ghosh
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

## Our own builder record (index, balance, status) as reported by a beacon
## node - see notes/0001-architecture-flow.md §3.1 and §7
##
## nimbus-eth2 does not serve `/eth/v1/beacon/states/{state_id}/builders`
## yet (notes/0005 Q2); the view then stays unknown and nimbu keeps running.

import
  std/strutils,
  chronos, results,
  stew/byteutils,
  ../rest/rest_builder_calls

export rest_builder_calls

type
  BuilderLookup* {.pure.} = enum
    Unknown
      ## Not queried yet, or the last query failed
    Found
    NotRegistered
      ## The beacon node knows no builder with our public key
    Unsupported
      ## The beacon node does not serve the builders endpoint

  BuilderViewRef* = ref object
    pubkey*: ValidatorPubKey
    lookup*: BuilderLookup
    info*: Opt[RestBuilderInfo]
      ## Shares the decoded `Builder` ref; only set when `lookup == Found`
    lastRefresh*: Opt[Slot]
    lastError*: string

func new*(T: type BuilderViewRef, pubkey: ValidatorPubKey): BuilderViewRef =
  BuilderViewRef(pubkey: pubkey)

func request*(view: BuilderViewRef): RestBuildersRequest =
  RestBuildersRequest(ids: @["0x" & view.pubkey.blob.toHex()])

func isUnsupportedStatus(status: int): bool =
  # Unknown routes: 404/405 from routers, 501 from some implementations
  status in [404, 405, 501]

proc applyResponse*(
    view: BuilderViewRef, response: RestPlainResponse, slot: Slot) =
  ## Updates the view from a `postStateBuildersPlain` response
  view.lastRefresh = Opt.some(slot)
  if response.status != 200:
    view.lastError = response.errorMessage()
    view.lookup =
      if response.status.isUnsupportedStatus and
          "state" notin view.lastError.toLowerAscii():
        BuilderLookup.Unsupported
      else:
        BuilderLookup.Unknown
    view.info.reset()
    return

  var decoded = decodeStateBuilders(response).valueOr:
    view.lastError = error
    view.lookup = BuilderLookup.Unknown
    view.info.reset()
    return

  view.lastError.setLen(0)
  for i in 0 ..< decoded.data.len:
    if not decoded.data[i].builder.isNil and
        decoded.data[i].builder[].pubkey == view.pubkey:
      view.lookup = BuilderLookup.Found
      view.info = Opt.some(move(decoded.data[i]))
      return
  view.lookup = BuilderLookup.NotRegistered
  view.info.reset()

proc refresh*(
    view: BuilderViewRef, client: RestClientRef,
    slot: Slot) {.async: (raises: [CancelledError]).} =
  let response =
    try:
      await client.postStateBuildersPlain(
        StateIdent.init(StateIdentType.Head), view.request())
    except RestError as exc:
      view.lookup = BuilderLookup.Unknown
      view.lastError = exc.msg
      view.lastRefresh = Opt.some(slot)
      return
  view.applyResponse(response, slot)
