# 0003 — What we reuse from nimbus-eth2

Status: living document · Last reviewed: 2026-10-06

Pinned: `status-im/nimbus-eth2` branch `unstable` @ `c3f68622` (2026-10-05),
`SPEC_VERSION = "1.7.0-beta.2"` (`beacon_chain/spec/datatypes/base.nim:83`).

Line numbers are for that commit. Re-verify them after every submodule bump.

nimbus-eth2 implements Gloas from the **proposer and client side** only. It
has no builder-side code. What it does give us:

- every type;
- the signing helpers;
- the exact checks proposers and gossip will run against our messages;
- a builder-API *client*. We serve the same routes, so this client doubles as
  our conformance test.

## 1. Import map

| Need                          | Module (under `vendor/nimbus-eth2/beacon_chain/`)                            | Key symbols                                                                                           | Coupling |
| ----------------------------- | ---------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- | -------- |
| Gloas types                   | `spec/datatypes/gloas.nim`                                                   | `ExecutionPayloadBid` (155), `SignedExecutionPayloadBid` (172), `ExecutionPayloadEnvelope` (177), `SignedExecutionPayloadEnvelope` (192), `SignedExecutionPayloadEnvelopeContents` (201), `ExecutionPayloadForSigning` (148), `Builder` (306), `ProposerPreferences` (327), `ExecutionRequests` (293) | low |
| Constants                     | `spec/datatypes/constants.nim`                                               | `DOMAIN_BEACON_BUILDER`, `BUILDER_INDEX_SELF_BUILD`, `PAYLOAD_BUILDER_VERSION`, `BUILDER_WITHDRAWAL_PREFIX` | low |
| Presets                       | `spec/presets.nim`, `spec/presets/*/gloas_preset.nim`                       | compile-time `-d:const_preset=mainnet\|minimal\|gnosis`                                               | low |
| Signing                       | `spec/signatures.nim`                                                        | `get_execution_payload_bid_signature` (456–480), `get_execution_payload_envelope_signature` (482–506), `verify_proposer_preferences_signature` (535–559), `verify_builder_request_auth_signature` (586–605), `verify_builder_deposit_signature` (229) | low |
| Builder-API types             | `spec/mev/gloas_mev.nim`                                                     | `DOMAIN_BUILDER_REQUEST_AUTH`, `BuilderRequestAuth`, `SignedBuilderRequestAuth`, `BuilderPreferences`, `BuilderPreferencesRequest` | low |
| Builder-API client (for tests)| `spec/mev/rest_mev_calls.nim`                                                | `getExecutionPayloadBid`, `submitSignedBeaconBlock`, `submitBuilderPreferences`, `getStatus`           | medium |
| Spec helpers                  | `spec/beaconstate.nim`, `consensus_object_pools/common_tools.nim:68`         | `can_builder_cover_bid` (3406), `is_active_builder` (3378), `is_gas_limit_target_compatible`           | medium |
| Proposer-side bid check       | `spec/state_transition_block.nim`                                            | `can_process_execution_payload_bid` (1255), `verify_execution_payload_envelope` (1824) — **tests only** | medium |
| Beacon REST client            | `spec/eth2_apis/rest_beacon_client.nim`                                      | `RestClientRef`, `publishExecutionPayloadEnvelope` (rest_beacon_calls 505/526), `getProposerDutiesV2Plain`, `subscribeEventStream` (rest_event_calls:14), `EventTopic` (rest_types:57) | **high** (see §2) |
| SSE consumption pattern       | `validator_client/block_service.nim:750–850`                                 | `response.getServerSentEvents()`                                                                      | reference only |
| Engine API                    | `el/el_manager.nim`, `el/el_conf.nim`, `el/engine_api_conversions.nim`       | `ELManager.new` (1153), `forkchoiceUpdated` (993/1063), `getPayload` (517), `asEngineExecutionPayload` (257) | medium |
| Payload attributes recipe     | `validators/block_payloads.nim:333–426`                                      | how a proposer fills `PayloadAttributesV4` for Gloas; `decodePayloadRequests` (169)                    | reference only (coupled to `BeaconNode`) |
| JWT                           | `spec/engine_authentication.nim`                                             | `JwtSharedKey`, `loadJwtSecretFile`                                                                   | low |
| Keystores                     | `spec/keystore.nim`                                                          | `decryptKeystore` (1153–1200)                                                                         | low/medium |
| SSZ / merkleization           | `spec/eth2_ssz_serialization.nim`, `spec/eth2_merkleization.nim`             | `hash_tree_root`, SSZ encode/decode                                                                   | low |
| Network configs               | `networking/network_metadata.nim`                                           | `getMetadataForNetwork`; **incbins** `vendor/{mainnet,sepolia,hoodi,gnosis-chain-configs,glamsterdam-devnets}` | needs eth2's data submodules |
| Beacon clock                  | `beacon_clock.nim`, `spec/beacon_time.nim`                                   | `BeaconClock`, `BeaconTime`, slot/BPS helpers                                                         | low |

## 2. Coupling hazards

- **The REST client pulls in about 74 modules.**
  `eth2_rest_json_serialization.nim:18` imports
  `consensus_object_pools/block_pools_types` because the SSE event object
  types live there (`block_pools_types.nim:407–435`). That in turn drags in:
  - `beacon_chain_db` (sqlite);
  - `era_db`, `validator_monitor`;
  - `libp2p/peerid`, snappy.

  It compiles, at a cost in build time. We accept this for v0 and, if it
  hurts, propose an upstream split (event types → `spec/`).
- **`validators/keystore_management.nim` and `validators/validator_pool.nim`
  import `../conf`**, which is the whole `BeaconNodeConf` tree. Do **not**
  import them. Re-implement the thin "load one keystore" path on top of
  `spec/keystore.nim`.
- **`networking/eth2_network.nim` requires a conf object** and pulls in
  `blockchain_dag` through `peer_protocol`. About 86 modules. Reuse only if
  decision D1 is revisited. The template for that case is
  `nimbus_light_client.nim:75–150`.
- **`validators/block_payloads.nim` is `BeaconNode`-coupled.** Copy the
  recipe, not the module.

## 3. Gaps we fill in nimbu (candidate upstream PRs)

| Gap | Where it would go upstream | nimbu stop-gap |
| --- | -------------------------- | -------------- |
| No REST client call for `POST /eth/v1/beacon/execution_payload_bids` (server exists at `rpc/rest_beacon_api.nim:1633`) | `spec/eth2_apis/rest_beacon_calls.nim` | `nimbu/rest/rest_builder_calls.nim` |
| `Web3SignerRequestKind` lacks an `EXECUTION_PAYLOAD_BID` kind (`rest_types.nim:485`) | `spec/eth2_apis/rest_types.nim` + remote signer | Local signing only |
| No builder-API **server** routes for Gloas | n/a (builder-side) | `nimbu/api/builder_api.nim` |
| nimbus BN does not serve `POST /eth/v1/beacon/states/{state_id}/builders` (no route in `rpc/`); the REST client has no call for it either | `rpc/rest_beacon_api.nim`, `spec/eth2_apis/rest_beacon_calls.nim` | Client call in `nimbu/rest/rest_builder_calls.nim`; `BuilderView` reports `Unsupported` against nimbus BNs (Lighthouse serves it) |
| SSE event types live in `block_pools_types` | move to `spec/` | accept heavier build |
| `rest_beacon_api.nim:1716–1725`: if the block is **not yet in the BN's DAG**, an envelope posted with blob data is gossiped but its blobs/proofs are discarded (`debugGloasComment`), returns 202 | upstream: keep blobs in quarantine | POST the envelope to a given BN only **after that BN has emitted the `block` event for N** (verified: when the block is known, the BN assembles columns via `assemble_data_column_sidecars`) |

## 4. Proposer-side behaviour that affects us

- **The local BN validator picks the bid** (`beacon_validators.proposeBlockAux`,
  Gloas flow about lines 466–780). It fetches the builder-API bid concurrently,
  takes the pool bid via `getHighestBidForProposalState`, and chooses with
  `selectBuilderBid` (`block_payloads.nim:680`), boost factor included.
- **When a builder bid wins, that BN does not call our
  `submitSignedBeaconBlock`.** Only the REST publish path with the
  `eth-builder-url` header does (`message_router_mev.nim:56`). This is why
  `RevealManager` must rely on SSE.
- **`getBuilderExecutionPayloadBid`** (`block_payloads.nim:524`) runs
  `can_process_execution_payload_bid` on our response, so an invalid
  builder-API bid is silently dropped.
- **Gossip validation is `validateExecutionPayloadBid`**
  (`gossip_validation.nim:1835`). Its Heze `inclusion_list_bits` check is
  still TODO.

## 5. Build-level facts

- **Nim 2.2.12**, pinned through `vendor/nimbus-build-system` @ `660fea59`.
  The nimble file says `requires "nim == 2.2.12"` and `config.nims` asserts it.
  The system Nim (2.2.0 on this machine) is **not** used; the build system
  bootstraps its own.
- **Compiler flags** from eth2's `config.nims`: `--threads:on --mm:refc`,
  `-d:metrics`, `-d:kzgExternalBlst`, `--noNimblePath`, and `warningAsError`
  for `UnusedImport`, `BareExcept` and others.
- **`beacon_chain/nim.cfg`** adds `-d:libp2p_pki_schemes=secp256k1`. Any
  module that imports libp2p transitively needs it.
