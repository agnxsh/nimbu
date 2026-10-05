# 0006 — Coding standards

Status: adopted · Last reviewed: 2026-10-06

nimbu follows nimbus-eth2's conventions. Where this note is silent, do what
nimbus-eth2 does and follow the
[Status Nim style guide](https://status-im.github.io/nim-style-guide/).

## 1. File header

Every `.nim`, `.nims` and `.cfg` file starts with:

```nim
# nimbu
# Copyright (c) 2026 Agnish Ghosh
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}
```

- The year range is updated when a file is modified (`2026-2027`). CI checks
  this.
- `{.push raises: [], gcsafe.}` is mandatory in non-test modules. CI enforces
  the regex `^{\.push raises: \[\](, gcsafe)?\.}$`, as in
  `nimbus-eth2/scripts/check_exception_headers.sh`.
- Test modules add `{.used.}`.

## 2. Errors and control flow

- **Use `Result[T, E]` and `Opt[T]` from `results` for expected failures.**
  Prefer `valueOr:`, `isOkOr:`, `?`, `ok()` and `err(...)`. Do not raise for
  control flow.
- **Error types:** `cstring` for spec-style checks; a typed enum or object
  when the caller branches on the error.
- **Message format** for spec-check messages: `"<spec_function_name>: <what failed>"`,
  e.g. `"process_execution_payload_bid: builder cannot cover bid"`.
- **No bare `except:`.** `BareExcept` is a warning-as-error. Catch specific
  exceptions at I/O boundaries and convert them into `Result`.

## 3. Async (chronos)

- **Declare raised exceptions explicitly:**
  `proc foo(): Future[T] {.async: (raises: [CancelledError]).}`.
- **REST wrappers** follow eth2's form:
  `{.async: (raises: [CancelledError, RestEncodingError, RestDnsResolveError, RestCommunicationError], raw: true).}`.
- **Every network call has a deadline.** Use `.wait(duration)` or
  `awaitWithTimeout`. Slot-bound work uses deadlines derived from
  `BeaconClock`.
- **Cancellation.** Long-lived loops must exit on cancellation, and owners
  call `cancelAndWait` in `stop`.
- **Threads.** No `threadvar` state and no blocking calls on the event loop.
  CPU-heavy work goes to `taskpools`.

## 4. Logging (chronicles)

- **One topic per module**, e.g. `logScope: topics = "reveal"`.
- **Message text:** sentence case, with no punctuation and no string
  interpolation. Context goes in key-value pairs:
  `info "Bid published", slot, builder_index, value = bid.value, block_hash = shortLog(bid.block_hash)`.
- **No emojis in log messages**, with one exception: the startup line
  `🍋 Starting nimbu`. More than that clutters the output.
- **Short logging.** Define `shortLog*` and `chronicles.formatIt` for our
  types.
- **Levels** follow `nimbus-eth2/docs/logging.md`:
  - `notice`: our own bids being included and our own reveals;
  - `info`: per-slot summaries;
  - `debug`: per-candidate and per-event detail;
  - `warn`: degraded operation (a BN is down);
  - `error`: a failed action we expected to succeed;
  - `fatal`: startup failure.
  - Use `critical`-style wording, at `error` level, for any path that can lose
    funds, such as a missing payload at reveal.

## 5. Naming and structure

- **Case.** Code identifiers are camelCase, types PascalCase, constants
  UPPER_SNAKE when they mirror spec constants.
  `--styleCheck:usages` is enabled.
- **Spec functions keep their spec name in snake_case**, e.g.
  `is_gas_limit_target_compatible`. Put the spec link above each one:
  ```nim
  # https://github.com/ethereum/consensus-specs/blob/<tag>/specs/gloas/builder.md#constructing-the-signedexecutionpayloadbid
  ```
  Builder-specs functions link to `ethereum/builder-specs` the same way.
- **Spec markers.** Use `[New in Gloas:EIP7732]` and `[Modified in …]` where
  we mirror spec code.
- **Prefer reuse.** Use nimbus-eth2 spec types and helpers over local copies.
  If something is missing, add it in `nimbu/` with a `# TODO upstream:` comment
  and an entry in [0003 §3](0003-nimbus-eth2-reuse.md#3-gaps-we-fill-in-nimbu-candidate-upstream-prs).
- **Module ownership.** Each module owns its state. Components talk through
  explicit procs and callbacks, with no global mutable state.
- **Formatting.** Two-space indent; see `.editorconfig`.
- **Exports.** Export with `*` only what other modules use. Re-export
  (`export foo`) only from facade modules.

## 6. Types and safety

- **Refs versus values.**
  - Use `ref` for long-lived components with identity (`...Ref` types like
    `ChainFollowerRef`, `ChainViewRef`).
  - Use `ref` for **large or shared payloads**: anything with a `seq`, or
    held by more than one owner. Examples are bids, payload attributes,
    proposer preferences and, from M2, execution payloads. Decode straight
    into `ref` fields (json_serialization supports `ref T`) so a payload is
    allocated once and shared by every cache.
  - Use values for small, short-lived bookkeeping: keys, digests,
    `Slot`/`Gwei`, summaries, enums, and small events such as
    `chain_reorg`.
  - Wrappers holding a ref to a shared payload plus a few fields are values
    (`HeadView`, `BestBid`, `BuildOpportunity`).
  - Why: Nim already passes non-`var` objects by pointer, so calls don't
    copy. Under `--mm:refc` a ref costs an allocation plus refcounting, and
    shared mutable state invites aliasing bugs.
- **Caches** use `minilru.LruCache` (qualified, since eth2 exports another
  `LruCache`) rather than `std/tables`, so memory is bounded. Read with
  `peek` so that lookups don't reorder entries.

- **Distinct types.** `Gwei`, `Slot`, `Epoch`, `BuilderIndex` and similar
  types come from nimbus-eth2. Don't convert them to raw integers except at
  serialization edges.
- **Arithmetic on balances** is checked or saturating. Any underflow in
  `RiskLedger` is a bug.
- **No `cast`** outside serialization code. `{.noinit.}` is used only with a
  justification comment.

## 7. Tests

- **Framework.** `unittest2` (`suite`/`test`), and `asyncTest` from
  `chronos/unittest2/asynctests`.
- **Layout.** One file per component, `tests/test_<component>.nim`,
  aggregated in `tests/all_tests.nim`.
- **Every bug fix gets a regression test.**
- **Conformance.** Builder-API server tests drive our server with nimbus-eth2's
  `rest_mev_calls` client. Bid and envelope tests validate output with
  nimbus-eth2's `can_process_execution_payload_bid` and
  `verify_execution_payload_envelope`.

## 8. Build and CI

- **Compiler flags.** `config.nims` mirrors eth2's:
  - `--threads:on --mm:refc`;
  - `-d:metrics`, `-d:kzgExternalBlst`;
  - `--noNimblePath`;
  - `warningAsError` for `UnusedImport`, `BareExcept` and others;
  - an assert that the Nim version is `(2, 2, 12)`.
- **CI matrix.** linux at minimum, then macOS.
- **CI lint job.** Exception headers, copyright year and the vendor-sync check
  (`scripts/sync_vendor.sh --check`).
- **Commits.** Small and focused, with imperative subject lines. Submodule
  bumps go in their own commit.

## 9. Notes discipline

Every non-trivial design choice or spec interpretation goes in
`notes/`: a new numbered note, or an entry in
[0005](0005-decisions-and-open-questions.md). Code comments link to the note
(`# see notes/0001 §3.4`) rather than repeating it.
