# 0005 — Decisions and open questions

Append-only log. When a question is answered, move it to **Decisions** with its
date and rationale. Never delete an entry; mark it superseded instead.

## Decisions

### D1 — Talk to the network through beacon nodes (REST + SSE), not our own libp2p node · 2026-10-06 · proposed

- **Why:**
  - beacon-APIs already expose everything a builder needs. That includes
    publishing bids and envelopes and the `head_v2`, `payload_attributes`,
    `proposer_preferences` and `execution_payload_bid` events. See
    [0002 §7](0002-gloas-spec-digest.md#7-beacon-node-rest--sse-surface-we-depend-on).
  - The BN performs gossip validation before broadcasting and derives the data
    columns from our blobs.
  - nimbus-eth2's `Eth2Node` needs a conf object and pulls in `blockchain_dag`.
- **Cost:**
  - The BN adds one extra hop of latency.
  - We depend on the BN's fork-choice view.
  - Mitigation: co-locate the BNs and fan out to several of them.
- **Revisit when:** latency measurements on devnets show the extra hop costs
  auctions.

### D2 — Vendor like nimbus-eth1: flat `vendor/`, `EXCLUDED_NIM_PACKAGES` for eth2's nested vendors · 2026-10-06 · proposed

- **Why:**
  - nimbus-eth1 already does this, so the build system supports it.
  - It gives one Nim search path.
- **Detail:** see [0004](0004-repo-layout-and-vendoring.md).

### D3 — Sign locally in v0 · 2026-10-06 · proposed

- **Why:** Web3Signer has no `EXECUTION_PAYLOAD_BID` request kind (see
  [0003 §3](0003-nimbus-eth2-reuse.md#3-gaps-we-fill-in-nimbu-candidate-upstream-prs)).

### D4 — Payload content comes from the EL's `engine_getPayloadV6` in v0, behind a `PayloadSource` interface · 2026-10-06 · proposed

- **Why:** this gets end-to-end ePBS mechanics working first. The MEV engine
  plugs in later without touching bidding or reveal.

### D5 — Persist payloads (WAL) before publishing any bid · 2026-10-06 · proposed

- **Why:** a bid that is included but has no payload costs us `value` and
  earns nothing. See [0001 §3.3](0001-architecture-flow.md#33-phase-c--pricing-and-bidding-late-n1--early-n).

### D6 — All implementation notes live in `notes/`, numbered `NNNN-topic.md` · 2026-10-06 · adopted

### D7 — Copyright holder is Agnish Ghosh; dual MIT / Apache-2.0 like nimbus-eth2; working name `nimbu` · 2026-10-06 · adopted

- **Header:** see [0006 §1](0006-coding-standards.md#1-file-header).
- **License files:** `LICENSE-MIT` and `LICENSE-APACHEv2`.

### D8 — Refs for components and large/shared payloads, values for small data · 2026-10-06 · adopted

- **Rule:** see [0006 §6](0006-coding-standards.md#6-types-and-safety).
- **History:** the M1 code first made everything a ref, then moved back for
  small event payloads and thin wrappers.

### D9 — Caches are `minilru` LRUs, not `std/tables` · 2026-10-06 · adopted

- **Why:** memory stays bounded even if a beacon node floods us with
  events.

### D10 — Log format: plain messages (only `🍋 Starting nimbu` keeps an emoji), no `tid=`/`file=` fields · 2026-10-06 · adopted

- **History:** an emoji per message was tried, then dropped as too cluttered.

- **Rule:** see [0006 §4](0006-coding-standards.md#4-logging-chronicles).
- **Config:** `nimbu/nimbu.nim.cfg` sets `chronicles_thread_ids=no` and
  `chronicles_line_numbers:0` for every build.
- **Tests:** silent unless `make test TEST_LOG=1`.

## Open questions

### Q1 — Project name and copyright holder · answered 2026-10-06 → D7

### Q2 — Exact builder balance accounting

- **The problem:** `can_builder_cover_bid` subtracts
  `builder_pending_withdrawals` and `builder_pending_payments` from the
  balance. The REST `/states/{id}/builders` endpoint only returns `balance`.
- **Option A:** our own ledger. It is conservative and needs no state.
- **Option B:** fetch the SSZ state once per epoch from
  `/eth/v2/debug/beacon/states/{id}`. This costs hundreds of MB on mainnet.
- **Option C:** propose a beacon-API extension that returns the builder's
  pending amount.
- **Lean:** A + C, with B only on devnets for cross-checking.
- **2026-10-06:** the endpoint is served by Lighthouse (glamsterdam-devnet-8:
  12,963 active builders) but not by nimbus-eth2. M1 `BuilderView` uses it
  when available.

### Q3 — EL head interference

- **The problem:** we call `engine_forkchoiceUpdated` with
  `parent_block_hash` for both EMPTY and FULL jobs. If the builder's EL is
  also the BN's EL, these calls fight over the EL's canonical head.
- **Lean:** require a dedicated EL (or pool of ELs) for building, separate
  from the BN's EL.
- **To verify:** confirm with the EL teams how Gloas ELs handle fCU for
  non-canonical heads with attributes.

### Q4 — nimbus BN drops blobs if the block isn't imported yet

- **What happens:** `rest_beacon_api.nim:1716–1725` handles an envelope posted
  with blob data. If the referenced block is not yet in the BN's DAG, the BN
  gossips the envelope but discards blobs and proofs, and responds 202. When
  the block *is* known, the BN builds and publishes the data column sidecars.
  This was verified in the source.
- **Mitigation, built into RevealManager:** per BN, POST only after that BN
  has emitted the `block` event for N, and treat a 202 as "retry".
- **Open:** whether to propose upstream that blobs be kept in quarantine.

### Q5 — Bid timing on the one-shot gossip path

- **The problem:** what `bid_deadline_bps` maximises the expected win
  probability times margin?
- **What to do:**
  - Needs devnet data on propagation latency versus proposer selection time.
  - Hedging across parent pairs (EMPTY/FULL, head/head-parent) gives at most
    2–3 shots per slot.

### Q6 — Builder-API exposure

- **The decision:** do we run the builder-API server publicly (pull path,
  `execution_payment` allowed) from day one?
- **Why it matters:** it adds DoS surface, and `auth.data` has to be
  distributed out of band.
- **Lean:** M5, after the p2p path works.

### Q7 — Target network for first integration

- **Candidates:**
  - a local Kurtosis devnet;
  - the `glamsterdam-devnets` vendored in nimbus-eth2.
- **Also needs deciding:** which EL. It must support `engine_getPayloadV6` and
  `PayloadAttributesV4`.

### Q8 — Spec drift

- **The problem:** the specs are pre-release (consensus `1.7.0-beta.x`), and
  [0002 §10](0002-gloas-spec-digest.md#10-known-spec-inconsistencies-track-until-resolved)
  lists inconsistencies between the repos.
- **Policy:** when they disagree, follow consensus-specs, then nimbus-eth2's
  behaviour. Record every deviation here.

### Q9 — Beacon nodes that don't emit `proposer_preferences` / `payload_attributes`

- **Observed 2026-10-06:** the public glamsterdam-devnet-8 beacon node
  (Lighthouse v8.3.0-rc.0) accepted subscriptions to both topics but sent
  no events in 30 s. In the same window, `head_v2` and
  `execution_payload_bid` events flowed normally, and bids pass gossip only
  when preferences have been seen. So preferences exist on the network; this
  node just doesn't expose them over SSE.
- **Likely cause:** Lighthouse emits `payload_attributes` only for local
  proposers unless started with `--always-prepare-payload`, and may not
  implement the `proposer_preferences` topic yet.
- **Impact:** M2 cannot start build jobs without these two topics.
- **Options:**
  - Require a BN that emits both; nimbus-eth2 wires both in
    `rpc/rest_event_api.nim`.
  - Run our own BN with "always prepare payload" behaviour.
  - Derive the attributes ourselves (they need the parent state's
    withdrawals) and get preferences from gossip, which reopens D1.
- **Next step:** test against a nimbus BN on the same devnet before M2.
