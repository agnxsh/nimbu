# nimbu
# Copyright (c) 2026 Agnish Ghosh
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

## Follows one or more beacon nodes over REST + SSE and feeds a shared
## `ChainViewRef` - see notes/0001-architecture-flow.md §3.1 and §4.1
##
## M1 is a dry run: every slot it logs what a builder would have seen
## (build opportunities, proposer preferences, competing bids), and once per
## epoch it refreshes our builder record. Nothing is built, signed or sent.
##
## Several beacon nodes feed the same view; caches are keyed like gossip so
## duplicate events are idempotent, and the latest `head_v2` from any node
## wins (notes/0005 D1).

import
  std/sequtils,
  chronos, chronicles, results,
  beacon_chain/beacon_clock,
  beacon_chain/spec/eth2_apis/rest_beacon_client,
  ./[builder_view, chain_view]

export chronos, chain_view, builder_view

logScope: topics = "chain"

const
  MinReconnectDelay = 1.seconds
  MaxReconnectDelay = 30.seconds
  SlotsKept = 2'u64
    ## Past slots kept in the caches; preferences for future slots are kept

type
  BeaconNodeRef* = ref object
    url*: string
    client*: RestClientRef
    connected*: bool
    eventsReceived*: uint64
    decodeErrors*: uint64

  ChainFollowerRef* = ref object
    timeParams: TimeParams
    genesisForkVersion: Version
    gloasForkEpoch: Epoch
    nodes*: seq[BeaconNodeRef]
    view*: ChainViewRef
    builder*: Opt[BuilderViewRef]
    clock*: Opt[BeaconClock]
    genesisValidatorsRoot*: Eth2Digest
    tasks: seq[Future[void].Raising([CancelledError])]

func shortLog*(node: BeaconNodeRef): string =
  node.url

chronicles.formatIt(BeaconNodeRef): shortLog(it)

proc new*(
    T: type ChainFollowerRef, cfg: RuntimeConfig, urls: openArray[string],
    builderPubkey: Opt[ValidatorPubKey]): Result[ChainFollowerRef, string] =
  if urls.len == 0:
    return err("At least one beacon node URL is required")
  var nodes: seq[BeaconNodeRef]
  for url in urls:
    let client = RestClientRef.new(url).valueOr:
      return err("Invalid beacon node URL '" & url & "': " & $error)
    nodes.add BeaconNodeRef(url: url, client: client)
  ok ChainFollowerRef(
    timeParams: cfg.timeParams,
    genesisForkVersion: cfg.GENESIS_FORK_VERSION,
    gloasForkEpoch: cfg.GLOAS_FORK_EPOCH,
    nodes: nodes,
    view: ChainViewRef.new(),
    builder: builderPubkey.map(proc(pubkey: ValidatorPubKey): BuilderViewRef =
      BuilderViewRef.new(pubkey)))

proc handleEvent*(
    follower: ChainFollowerRef, node: BeaconNodeRef, topic, data: string) =
  inc node.eventsReceived
  let decoded = decodeChainEvent(topic, data).valueOr:
    inc node.decodeErrors
    warn "Undecodable event from beacon node", node, topic, error
    return
  let event = decoded.valueOr:
    return # a topic nimbu does not consume
  case follower.view.apply(event)
  of ApplyResult.Ignored, ApplyResult.Updated:
    trace "Chain event", node, topic
  of ApplyResult.NewHead:
    debug "New head", node,
      slot = event.head.slot,
      root = shortLog(event.head.block_root),
      payloadStatus = event.head.payload_status
  of ApplyResult.PayloadRevealed:
    debug "Head payload revealed", node,
      slot = event.head.slot, root = shortLog(event.head.block_root)
  of ApplyResult.NewOpportunity:
    debug "Build opportunity", node,
      proposalSlot = event.attributes.proposal_slot,
      proposerIndex = event.attributes.proposer_index,
      parentRoot = shortLog(event.attributes.parent_block_root),
      parentHash = shortLog(event.attributes.parent_block_hash)
  of ApplyResult.NewBestBid:
    debug "New best competing bid", node,
      slot = event.bid.message.slot,
      builderIndex = event.bid.message.builder_index,
      value = event.bid.message.value

proc consumeEvents(
    follower: ChainFollowerRef,
    node: BeaconNodeRef): Future[bool] {.async: (raises: [CancelledError]).} =
  ## Reads the event stream until it ends; `true` if it delivered anything
  let response =
    try:
      await node.client.subscribeEventStream(ChainEventTopics)
    except RestError as exc:
      debug "Unable to open event stream", node, reason = exc.msg
      return false

  try:
    if response.status != 200:
      let body =
        try:
          await response.getBodyBytes()
        except HttpError:
          @[]
      warn "Beacon node refused event stream", node,
        status = response.status,
        reason = RestPlainResponse(status: response.status, data: body)
          .errorMessage()
      return false

    node.connected = true
    info "Event stream connected", node
    var
      topic = ""
      delivered = false
    while true:
      let events =
        try:
          await response.getServerSentEvents()
        except HttpError as exc:
          debug "Event stream error", node, reason = exc.msg
          return delivered
      if events.len == 0:
        return delivered
      for event in events:
        case event.name
        of "event":
          topic = event.data
        of "data":
          delivered = true
          follower.handleEvent(node, topic, event.data)
        else:
          discard
  finally:
    node.connected = false
    await noCancel response.closeWait()

proc runEventLoop(
    follower: ChainFollowerRef,
    node: BeaconNodeRef) {.async: (raises: [CancelledError]).} =
  var delay = MinReconnectDelay
  while true:
    if await follower.consumeEvents(node):
      delay = MinReconnectDelay
    warn "Event stream disconnected, reconnecting", node, delay
    await sleepAsync(delay)
    delay = min(delay * 2, MaxReconnectDelay)

proc fetchGenesis(
    follower: ChainFollowerRef): Future[Result[RestGenesis, string]] {.
    async: (raises: [CancelledError]).} =
  var lastError = "no beacon node configured"
  for node in follower.nodes:
    try:
      let response = await node.client.getGenesis()
      return ok(response.data.data)
    except RestError as exc:
      lastError = node.url & ": " & exc.msg
  err(lastError)

proc logSlotSummary(follower: ChainFollowerRef, slot: Slot) =
  let summary = follower.view.summarize(slot)
  info "Slot summary",
    slot,
    headSlot = summary.head.map(proc(h: HeadView): Slot = h.slot),
    headPayload = summary.head.map(
      proc(h: HeadView): HeadPayloadStatus = h.payloadStatus),
    opportunities = summary.opportunities,
    withPreferences = summary.opportunitiesWithPrefs,
    bestBid = summary.bestBid.map(proc(b: BestBid): Gwei = b.value),
    bestBidBuilder = summary.bestBid.map(
      proc(b: BestBid): uint64 = b.bid[].message.builder_index),
    connectedNodes = follower.nodes.countIt(it.connected)

proc refreshBuilder(
    follower: ChainFollowerRef,
    slot: Slot) {.async: (raises: [CancelledError]).} =
  let builder = follower.builder.valueOr:
    return
  let node = block:
    var res = follower.nodes[0]
    for node in follower.nodes:
      if node.connected:
        res = node
        break
    res
  await builder.refresh(node.client, slot)
  case builder.lookup
  of BuilderLookup.Found:
    let info = builder.info.get
    info "Builder status", slot,
      builderIndex = info.index, status = info.status,
      balance = info.builder[].balance,
      withdrawableEpoch = info.builder[].withdrawable_epoch
  of BuilderLookup.NotRegistered:
    warn "Builder not registered on the beacon chain", slot,
      pubkey = shortLog(builder.pubkey)
  of BuilderLookup.Unsupported:
    warn "Beacon node does not serve the builders endpoint", slot, node,
      reason = builder.lastError
  of BuilderLookup.Unknown:
    warn "Unable to refresh builder status", slot, node,
      reason = builder.lastError

proc runSlotLoop(follower: ChainFollowerRef) {.
    async: (raises: [CancelledError]).} =
  let clock = follower.clock.get
  var refreshedEpoch = Opt.none(Epoch)
  while true:
    let nextSlot = clock.currentSlot() + 1
    await sleepAsync(clock.fromNow(nextSlot).durationOrZero)

    if nextSlot > 0:
      follower.logSlotSummary(nextSlot - 1)
    if nextSlot > SlotsKept:
      follower.view.prune(nextSlot - SlotsKept)

    let epoch = nextSlot.epoch
    if nextSlot == epoch.start_slot:
      if epoch < follower.gloasForkEpoch:
        info "Waiting for Gloas fork", epoch,
          gloasForkEpoch = follower.gloasForkEpoch,
          epochsLeft = follower.gloasForkEpoch - epoch
      elif epoch == follower.gloasForkEpoch:
        notice "Gloas fork activated", epoch, slot = nextSlot

    # Builders only exist from Gloas on; beacon nodes reject the query before
    if epoch >= follower.gloasForkEpoch and
        refreshedEpoch != Opt.some(epoch):
      refreshedEpoch = Opt.some(epoch)
      await follower.refreshBuilder(nextSlot)

proc waitForGenesis(follower: ChainFollowerRef): Future[RestGenesis] {.
    async: (raises: [CancelledError]).} =
  ## Beacon nodes may come up after nimbu; keep trying until one answers
  var delay = MinReconnectDelay
  while true:
    let res = await follower.fetchGenesis()
    if res.isOk:
      return res.get
    warn "No beacon node reachable, retrying", reason = res.error, delay
    await sleepAsync(delay)
    delay = min(delay * 2, MaxReconnectDelay)

proc start*(follower: ChainFollowerRef): Future[Result[void, string]] {.
    async: (raises: [CancelledError]).} =
  ## Waits for a beacon node, checks it is on our network and starts
  ## following it; fails only on unrecoverable configuration errors
  let genesis = await follower.waitForGenesis()
  if genesis.genesis_fork_version != follower.genesisForkVersion:
    return err("Beacon node is on a different network: genesis fork " &
      "version " & $genesis.genesis_fork_version & ", expected " &
      $follower.genesisForkVersion)
  follower.clock = BeaconClock.init(follower.timeParams, genesis.genesis_time)
  if follower.clock.isNone:
    return err("Invalid genesis time " & $genesis.genesis_time)
  follower.genesisValidatorsRoot = genesis.genesis_validators_root

  let wallEpoch = follower.clock.get.currentSlot().epoch
  info "Following beacon chain",
    nodes = follower.nodes.mapIt(it.url),
    gloasForkEpoch = follower.gloasForkEpoch,
    gloasActive = wallEpoch >= follower.gloasForkEpoch,
    genesisTime = genesis.genesis_time,
    genesisValidatorsRoot = shortLog(genesis.genesis_validators_root),
    wallSlot = follower.clock.get.currentSlot()

  for node in follower.nodes:
    follower.tasks.add follower.runEventLoop(node)
  follower.tasks.add follower.runSlotLoop()
  ok()

proc stop*(follower: ChainFollowerRef) {.async: (raises: []).} =
  let pending = follower.tasks.mapIt(it.cancelAndWait())
  follower.tasks.setLen(0)
  await noCancel allFutures(pending)
  for node in follower.nodes:
    await node.client.closeWait()
