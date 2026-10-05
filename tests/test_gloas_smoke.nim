# nimbu
# Copyright (c) 2026 Agnish Ghosh
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}
{.used.}

## M0 smoke test: proves that the vendored nimbus-eth2 Gloas types, SSZ
## merkleization and BLS signing helpers compile and link from nimbu

import
  unittest2,
  stew/byteutils,
  beacon_chain/spec/[crypto, eth2_merkleization, signatures],
  beacon_chain/spec/datatypes/gloas

const
  # EIP-2333 test vector secret, also used by nimbus-eth2 keystore tests
  secretHex =
    "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f"

suite "Gloas smoke test":
  setup:
    let
      privkey = ValidatorPrivKey.fromRaw(hexToSeqByte(secretHex)).get()
      pubkey = privkey.toPubKey()
      fork = Fork(
        previous_version: Version([byte 0x06, 0, 0, 0]),
        current_version: Version([byte 0x07, 0, 0, 0]),
        epoch: Epoch(0))
      gvr = Eth2Digest.fromHex(
        "0x4b363db94e286120d76eb905340fdd4e54bfe9f06bf33ff6cf5ad27f511bfe95")
      bid = gloas.ExecutionPayloadBid(
        slot: Slot(32),
        builder_index: 7,
        value: Gwei(1_000_000_000),
        gas_limit: 60_000_000)

  test "ExecutionPayloadBid hash_tree_root covers value":
    var other = bid
    other.value = Gwei(1_000_000_001)
    check hash_tree_root(bid) != hash_tree_root(other)

  test "ExecutionPayloadBid signature round-trip":
    let sig = get_execution_payload_bid_signature(
      fork, gvr, bid.slot.epoch, bid, privkey).toValidatorSig()
    check:
      verify_execution_payload_bid_signature(
        fork, gvr, bid.slot.epoch, bid, pubkey, sig)
      not verify_execution_payload_bid_signature(
        fork, ZERO_HASH, bid.slot.epoch, bid, pubkey, sig)
