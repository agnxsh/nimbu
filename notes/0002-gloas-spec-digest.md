# 0002 — Gloas spec digest (builder's view)

Status: living document · Last reviewed: 2026-10-06

This note distils the parts of the Gloas (EIP-7732, ePBS) specification that
an external builder must implement or reason about. It is not a substitute for
the spec; every section links back to the source of truth.

## Pinned spec versions

| Repo                      | Commit    | Date       | Notes                                   |
| ------------------------- | --------- | ---------- | --------------------------------------- |
| `ethereum/consensus-specs`| `4e51b71` | 2026-10-05 | `specs/gloas/*`                         |
| `ethereum/builder-specs`  | `61aeca4` | 2026-09-18 | `specs/gloas/*`, `builder-oapi.yaml`    |
| `ethereum/beacon-APIs`    | `51142ef` | 2026-09-30 | types reference consensus `v1.7.0-beta.0` |

When bumping, re-read the diffs of the files listed in each section below and
update this table.

## 1. Who a builder is

- A **builder is a staked, non-validator actor** with its own registry
  (`state.builders`, type `Builder`) and its own index space (`BuilderIndex`).
  It does not attest or propose and earns no yield.
- `Builder{pubkey, version, execution_address, balance, deposit_epoch, withdrawable_epoch}`.
- **Onboarding** (EIP-8282): send a builder deposit request to the EL builder
  deposit contract (`BUILDER_DEPOSIT_REQUEST_TYPE = 0x03`), withdrawal
  credentials `0xB0 ‖ 0x00*11 ‖ execution_address`, proof-of-possession signed
  under `DOMAIN_BUILDER_DEPOSIT = 0x0E000000`. A deposit for an existing pubkey
  is a top-up.
- **Activation**: active once `deposit_epoch` is finalized (≈ 2 epochs).
- **Exit**: EL builder exit request (`0x04`) sent *from* `execution_address`
  (not BLS-signed). Refused while any payment is pending.
  `MIN_BUILDER_WITHDRAWABILITY_DELAY = 64` epochs. Indices may be reused.
- Our own index/balance is resolved via beacon API
  `POST /eth/v1/beacon/states/{state_id}/builders`.

Source: `consensus-specs/specs/gloas/builder.md` §Becoming a builder;
`beacon-chain.md` §Builder deposit requests / exit requests.

## 2. Objects the builder produces

| Object                              | Signed with                                                              | Sent via                       |
| ----------------------------------- | ------------------------------------------------------------------------ | ------------------------------ |
| `SignedExecutionPayloadBid`         | `get_domain(state, DOMAIN_BEACON_BUILDER, epoch(bid.slot))`              | gossip `execution_payload_bid` / builder-API pull |
| `SignedExecutionPayloadEnvelope`    | `get_domain(state, DOMAIN_BEACON_BUILDER, epoch(state.slot))`            | gossip `execution_payload`     |
| `DataColumnSidecar` × N             | unsigned (commitments are in the bid inside the signed block)           | gossip `data_column_sidecar_{subnet}` |

`DOMAIN_BEACON_BUILDER = 0x0B000000`.

### `ExecutionPayloadBid` (ProgressiveContainer, EIP-7688)

| Field                     | How the builder sets it                                                                 |
| ------------------------- | --------------------------------------------------------------------------------------- |
| `parent_block_hash`       | `payload.parent_hash` — FULL parent: head bid's `block_hash`; EMPTY parent: `state.latest_block_hash` |
| `parent_block_root`       | head block root (`hash_tree_root(state.latest_block_header)`)                            |
| `block_hash`              | `payload.block_hash`                                                                     |
| `prev_randao`             | `get_randao_mix(parent_state, current_epoch)` (== `payload.prev_randao`)                 |
| `fee_recipient`           | **proposer's** address from `SignedProposerPreferences` for `(bid.slot, dependent_root)` |
| `gas_limit`               | `payload.gas_limit`; must satisfy `is_gas_limit_target_compatible(parent_gl, gl, prefs.target_gas_limit)` |
| `builder_index`           | our index                                                                                |
| `slot`                    | current or next slot                                                                     |
| `value`                   | trustless payment to proposer (gwei), debited from CL builder balance                   |
| `execution_payment`       | 0 on gossip (REJECT otherwise); may be >0 only on the builder-API (trusted) path        |
| `blob_kzg_commitments`    | `blobsBundle.commitments` from `engine_getPayloadV6`                                     |
| `execution_requests_root` | `hash_tree_root(execution_requests)` from `engine_getPayloadV6`                          |

Note the two fee recipients: `bid.fee_recipient` receives the CL payment;
`payload.fee_recipient` (EL coinbase) is the builder's own address and collects
EL priority fees / MEV.

### `ExecutionPayloadEnvelope`

`{payload, execution_requests, builder_index (== bid.builder_index),
beacon_block_root (= htr(block)), parent_beacon_block_root (= block.parent_root)}`.

## 3. Payment semantics (why bid sizing is a risk problem)

- `process_execution_payload_bid` records a `BuilderPendingPayment` for the
  slot. `can_builder_cover_bid` requires
  `balance − (MIN_DEPOSIT_AMOUNT + pending withdrawals + pending payments) ≥ value`.
- **Payload processing is deferred** to the *next* beacon block
  (`process_parent_execution_payload` → `apply_parent_execution_payload`).
  That is where the payment is settled and the parent payload's execution
  requests are applied.
- Payment is also settled at epoch processing if same-slot attestation weight
  ≥ 60 % quorum (`BUILDER_PAYMENT_THRESHOLD_NUMERATOR/DENOMINATOR = 6/10`) —
  **the builder pays even when it withholds the payload** once the block is
  well attested.
- Payment is voided if the proposer is slashed for that slot.

Consequence: the bid ceiling must be computed from *our own view* of builder
balance minus all in-flight bids that could still be included. See
[0001 §Risk & accounting](0001-architecture-flow.md#7-risk--accounting).

## 4. Choosing the parent (FULL vs EMPTY)

- Fork-choice nodes are `(root, payload_status ∈ {PENDING, EMPTY, FULL})`.
- `should_build_on_full(store, head, slot)` decides; a builder has only an
  external view of the store, so it relies on the beacon node:
  `head_v2` SSE carries `payload_status` and is re-emitted on EMPTY→FULL;
  `payload_attributes` SSE carries `parent_block_root` + `parent_block_hash`.
- Gossip `is_bid_compatible_with_head` also accepts bids that build on the
  head's *parent* with the same parent hash (anticipating a proposer re-org of
  a weak head).
- **Hedging is allowed**: one gossip bid per
  `(slot, parent_block_hash, parent_block_root, builder_index)`, so a builder
  can bid once on FULL and once on EMPTY (or head vs. head-parent).
- Withdrawals for the payload attributes:
  FULL parent → copy state, `apply_parent_execution_payload`, then
  `get_expected_withdrawals`; EMPTY parent → `state.payload_expected_withdrawals`.
  In practice taken from the `payload_attributes` SSE event.

Source: `fork-choice.md`, `validator.md` §Signed execution payload bid,
`p2p-interface.md` §is_bid_compatible_with_head.

## 5. Gossip rules that constrain bidding (`execution_payload_bid`)

Ordered as in `p2p-interface.md` (≈ L956). The builder must satisfy all of them
locally *before* sending, since a 400 from the beacon node costs the slot.

1. **One bid per `(slot, parent_hash, parent_root, builder)`** — no updates over
   gossip. (IGNORE)
2. Forwarded only if `value` > best seen for `(slot, parent_hash, parent_root)`. (IGNORE)
3. `slot` is current or next. (IGNORE)
4. `execution_payment == 0`. (REJECT)
5. `block_hash != parent_block_hash`. (REJECT)
6. `len(blob_kzg_commitments) ≤ max_blobs_per_block(epoch)`. (REJECT)
7. Parent block known; `bid.slot > parent.slot`; parent state available.
8. Proposer preferences for `(bid.slot, dependent_root)` seen; `fee_recipient` matches. (IGNORE)
9. `parent_block_hash` is a known (seen & valid) payload. (IGNORE)
10. Gas-limit target compatibility. (IGNORE)
11. `is_bid_compatible_with_head`. (IGNORE)
12. `prev_randao` correct. (REJECT)
13. Builder in range, `version == 0`, active (REJECT); can cover bid (IGNORE).
14. Parent FULL payload does not contain an exit for this builder. (IGNORE)
15. Signature valid. (REJECT)

Rule 1 is the most consequential for design: on the p2p path the builder gets
**one shot per parent pair**, so the bid must be timed late enough to be
competitive and early enough to propagate. The builder-API pull path (§6) is
the only way to answer "latest/best" on demand.

## 6. Builder API (builder-specs, Gloas)

The builder MAY additionally run an HTTP server that proposers' beacon nodes
call (trusted path):

| Endpoint                                                                                     | Purpose                                                        |
| -------------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| `POST /eth/v1/builder/execution_payload_bid/{slot}/{parent_hash}/{parent_root}/{proposer_pubkey}` | Return best bid now (200) or 204. Headers `Date-Milliseconds`, `X-Timeout-Ms`, `Eth-Consensus-Version`; body `SignedBuilderRequestAuth`. |
| `POST /eth/v1/builder/builder_preferences/{proposer_pubkey}`                                 | Proposer's `max_execution_payment` cap (202).                  |
| `POST /eth/v1/builder/beacon_blocks`                                                         | Proposer's BN pushes the signed block containing our bid → early reveal trigger. |
| `GET  /eth/v1/builder/status`                                                                | Liveness.                                                      |

- Auth: `SignedBuilderRequestAuth{BuilderRequestAuth{data ≤ 4096 B, slot}}`
  under `DOMAIN_BUILDER_REQUEST_AUTH = 0x0B000001` (genesis-style domain).
  Default `data` is the builder URL hostname (`get_default_auth_data`).
- Proposer valuation: `value + min(execution_payment, max_execution_payment)`.
- Pre-Gloas endpoints (`registerValidator`, `getHeader`, blinded blocks) are
  out of scope.

## 7. Beacon node REST + SSE surface we depend on

| Use                          | Endpoint / topic                                                                  |
| ---------------------------- | --------------------------------------------------------------------------------- |
| Head + payload status        | SSE `head_v2` (`payload_status`, dependent roots)                                 |
| Build trigger + attributes   | SSE `payload_attributes` (Gloas form: `parent_block_root`, `parent_block_hash`, `withdrawals`, `slot_number`, `target_gas_limit`, …) |
| Proposer prefs               | SSE `proposer_preferences` (full `SignedProposerPreferences`)                     |
| Competing bids               | SSE `execution_payload_bid`                                                       |
| Did our bid win              | SSE `block` / `block_gossip` + `GET /eth/v2/beacon/blocks/{id}`; builder-API `beacon_blocks` push |
| Payload seen / available     | SSE `execution_payload_gossip`, `execution_payload`, `execution_payload_available` |
| Reorgs                       | SSE `chain_reorg`                                                                 |
| Our builder record           | `POST /eth/v1/beacon/states/{state_id}/builders`                                  |
| Lookahead                    | `GET /eth/v1/beacon/states/{state_id}/proposer_lookahead`, `GET /eth/v2/validator/duties/proposer/{epoch}` |
| Publish bid                  | `POST /eth/v1/beacon/execution_payload_bids` (200 = passed gossip validation)     |
| Publish envelope + blobs     | `POST /eth/v1/beacon/execution_payload_envelopes?broadcast_validation=consensus_and_equivocation` with `Eth-Blob-Data-Included: true`, body `SignedExecutionPayloadEnvelopeContents{signed_execution_payload_envelope, kzg_proofs, blobs}` — BN computes and gossips data columns |
| Genesis / fork / spec        | `GET /eth/v1/beacon/genesis`, `/eth/v1/config/spec`, `/eth/v1/config/fork_schedule` |

## 8. Timing (mainnet, `SLOT_DURATION_MS = 12000`)

| Deadline                       | BPS  | t into slot |
| ------------------------------ | ---- | ----------- |
| Attestation (`ATTESTATION_DUE_BPS_GLOAS`) | 2500 | 3 s |
| Aggregate                      | 5000 | 6 s         |
| **Payload reveal (`PAYLOAD_DUE_BPS`)** | 5000 | **6 s** |
| **PTC vote (`PAYLOAD_ATTESTATION_DUE_BPS`)** | 7500 | **9 s** |

Envelope + data columns must be *seen by PTC members* before 6 s; aim to publish
by ~4 s. All deadlines are expressed in basis points and must be computed from
the runtime config, never hard-coded (EIP-8198 "quick slots" will change them).

## 9. Honest withholding

If the block that includes our bid was not timely / is not our head, the
builder MAY withhold the payload (act as if no block). Caveat from §3: payment
can still be settled by attestation quorum.

## 10. Known spec inconsistencies (track until resolved)

1. builder-specs calls the gossip topic `execution_payload_envelope`;
   consensus-specs calls it `execution_payload`. We follow consensus-specs.
2. builder-specs prose deprecates `registerValidator` / `getHeader`; the yaml
   has no `deprecated` flag.
3. beacon-APIs text says bids with mismatched `fee_recipient` are "rejected";
   consensus-specs says IGNORE.
4. beacon-APIs CHANGES.md lists `payload_attestation_data/{slot}`; the API
   defines `slot` as a query parameter.
5. builder-specs uses `state.latest_block_hash` for an EMPTY parent;
   consensus `validator.md` uses `state.latest_execution_payload_bid.parent_block_hash`
   (equal after block processing).

## 11. On the horizon

- **Heze (FOCIL, EIP-7805)**: bid gains `inclusion_list_bits`; gossip IGNOREs
  bids not inclusive of the ILs (`specs/heze/builder.md`). Design the payload
  builder so IL constraints can be fed into EL building later.
- **EIP-8025**: builders may later be required to produce execution proofs.
- **EIP-8148 / EIP-8205**: new EL request types → `ExecutionRequests` grows →
  `execution_requests_root` changes. Always use nimbus-eth2 types, never
  hand-rolled ones.
- **EIP-8198 quick slots**: 10 s slots; deadlines scale (see §8).
