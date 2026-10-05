# nimbu
# Copyright (c) 2026 Agnish Ghosh
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

## Minimal beacon node REST + SSE server for component tests: serves
## `/eth/v1/beacon/genesis`, `/eth/v1/events` (a scripted list of events,
## then the stream ends) and `/eth/v1/beacon/states/{id}/builders`.

import
  std/strutils,
  chronos, chronos/apps/http/httpserver

export httpserver

type
  MockEvent* = tuple[topic: string, data: string]

  MockBeaconNodeRef* = ref object
    server: HttpServerRef
    genesisJson*: string
    events*: seq[MockEvent]
    buildersStatus*: HttpCode
    buildersJson*: string
    eventStreamsOpened*: int
    buildersRequests*: int
    lastBuildersBody*: string

proc handle(
    mock: MockBeaconNodeRef,
    request: HttpRequestRef): Future[HttpResponseRef] {.
    async: (raises: [CancelledError]).} =
  let path = request.uri.path
  try:
    if request.meth == MethodGet and path == "/eth/v1/beacon/genesis":
      return await request.respond(Http200, mock.genesisJson,
        HttpTable.init([("Content-Type", "application/json")]))

    if request.meth == MethodGet and path == "/eth/v1/events":
      inc mock.eventStreamsOpened
      let response = request.getResponse()
      await response.prepareSSE()
      for event in mock.events:
        await response.sendEvent(event.topic, event.data)
      await response.finish()
      return response

    if request.meth == MethodPost and path.startsWith("/eth/v1/beacon/states/") and
        path.endsWith("/builders"):
      inc mock.buildersRequests
      mock.lastBuildersBody = bytesToString(await request.getBody())
      return await request.respond(mock.buildersStatus, mock.buildersJson,
        HttpTable.init([("Content-Type", "application/json")]))

    await request.respond(Http404,
      """{"code": 404, "message": "Route not found"}""",
      HttpTable.init([("Content-Type", "application/json")]))
  except HttpError as exc:
    defaultResponse(exc)

proc new*(T: type MockBeaconNodeRef): Result[MockBeaconNodeRef, string] =
  let mock = MockBeaconNodeRef(buildersStatus: Http200)
  proc process(fence: RequestFence): Future[HttpResponseRef] {.
      async: (raises: [CancelledError]).} =
    if fence.isErr():
      return defaultResponse()
    await mock.handle(fence.get())

  let address =
    try:
      initTAddress("127.0.0.1:0")
    except TransportAddressError as exc:
      return err(exc.msg)
  mock.server = HttpServerRef.new(
    address, process,
    socketFlags = {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr}).valueOr:
      return err($error)
  mock.server.start()
  ok mock

func url*(mock: MockBeaconNodeRef): string =
  "http://" & $mock.server.instance.localAddress()

proc closeWait*(mock: MockBeaconNodeRef) {.async: (raises: []).} =
  await mock.server.stop()
  await mock.server.closeWait()
