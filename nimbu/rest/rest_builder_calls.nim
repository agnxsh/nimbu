# nimbu
# Copyright (c) 2026 Agnish Ghosh
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

## Beacon API calls nimbus-eth2's REST client does not provide yet.
## TODO upstream: notes/0003-nimbus-eth2-reuse.md §3

import
  results,
  stew/byteutils,
  presto/client,
  beacon_chain/spec/eth2_apis/[eth2_rest_serialization, rest_types]

export client, rest_types, eth2_rest_serialization

type
  RestBuildersRequest* = object
    ## https://github.com/ethereum/beacon-APIs/blob/51142ef/apis/beacon/states/builders.yaml
    ids*: seq[string]
      ## Hex public keys or builder indices; empty for all builders

  RestBuilderInfo* = object
    index*: uint64
    status*: string
    builder*: ref gloas.Builder

  GetStateBuildersResponse* = object
    execution_optimistic*: Opt[bool]
    finalized*: Opt[bool]
    data*: seq[RestBuilderInfo]

RestJson.useDefaultSerializationFor(
  RestBuildersRequest, RestBuilderInfo, GetStateBuildersResponse)

proc encodeBytes*(
    value: RestBuildersRequest, contentType: string): RestResult[seq[byte]] =
  case contentType
  of "application/json":
    ok RestJson.encode(value).toBytes()
  else:
    err("Content-Type not supported")

proc postStateBuildersPlain*(
    state_id: StateIdent,
    body: RestBuildersRequest
): RestPlainResponse {.
    rest, endpoint: "/eth/v1/beacon/states/{state_id}/builders",
    meth: MethodPost.}
  ## https://ethereum.github.io/beacon-APIs/#/Beacon/getStateBuilders

proc decodeStateBuilders*(
    response: RestPlainResponse): Result[GetStateBuildersResponse, string] =
  try:
    ok RestJson.decode(response.data, GetStateBuildersResponse)
  except SerializationError as exc:
    err exc.formatMsg("<response>")

proc errorMessage*(response: RestPlainResponse): string =
  ## Best-effort `message` of a beacon API error response
  try:
    RestJson.decode(response.data, RestErrorMessage).message
  except SerializationError:
    "HTTP " & $response.status
