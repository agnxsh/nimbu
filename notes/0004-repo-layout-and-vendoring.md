# 0004 — Repository layout and vendoring

Status: applied in M0 · Last reviewed: 2026-10-06

We follow the pattern **nimbus-eth1** already uses to consume nimbus-eth2:

- a flat `vendor/` with every Nim dependency as a direct submodule;
- plus `vendor/nimbus-eth2` itself;
- eth2's *own* nested `vendor/*` excluded from the Nim path.

## 1. Layout

```
nimbu/
├── Makefile                  # nimbus-build-system driven (see §3)
├── env.sh                    # sources vendor/nimbus-build-system/scripts/env.sh
├── config.nims               # mirrors nimbus-eth2/config.nims (flags, Nim version assert)
├── nimbu.nimble              # metadata + `requires` (documentation; build uses vendor/)
├── .gitmodules
├── .editorconfig             # copied from nimbus-eth2
├── LICENSE-MIT
├── LICENSE-APACHEv2
├── README.md
├── nimbu/                    # sources (analogue of beacon_chain/)
│   ├── nim.cfg               # -d:libp2p_pki_schemes=secp256k1, --styleCheck:usages
│   ├── nimbu.nim     # main: confutils dispatch → run / deposit-data / status
│   ├── conf.nim
│   ├── version.nim
│   ├── chain/                # chain_follower, prefs_cache, bid_observer, builder_view
│   ├── building/             # build_scheduler, build_job, payload_source, payload_store
│   ├── bidding/              # bid_strategy, bid_factory, risk_ledger
│   ├── signing/              # builder_signer
│   ├── publishing/           # publisher, reveal_manager
│   ├── api/                  # builder_api (builder-specs server), admin
│   ├── rest/                 # REST client calls missing upstream (rest_builder_calls)
│   └── tools/                # deposit_data, …
├── tests/
│   ├── all_tests.nim
│   ├── test_*.nim
│   └── mocks/                # mock BN (SSE + REST), mock EL (json-rpc)
├── scripts/                  # check_exception_headers.sh, check_copyright_year.sh, sync_vendor.sh
├── notes/                    # implementation notes (this directory)
└── vendor/
    ├── nimbus-build-system/
    ├── nimbus-eth2/          # branch `unstable`, pinned commit
    ├── nim-chronos/ nim-chronicles/ nim-results/ nim-stew/ …   # every lib eth2 uses
    └── …
```

## 2. Which submodules

| Group | Submodules | Notes |
| ----- | ---------- | ----- |
| Build | `nimbus-build-system` | Provides the pinned Nim compiler (2.2.12) |
| Core  | `nimbus-eth2` | Branch `unstable`. Only its data submodules get initialised (below) |
| Libs  | Every `vendor/nim-*`, `NimYAML` and `nimcrypto` entry of nimbus-eth2's `.gitmodules` | **Same commits** as eth2 pins |
| Skip  | `nimbus-benchmarking`, `nim-eth2-scenarios` | Test vectors and benchmarks we don't need. `nimbus-security-resources` is still mirrored: only eth2's `validators/keystore_management.nim` imports it (we don't yet), but keeping the full set makes sync checks simple |

Inside `vendor/nimbus-eth2`, initialise only the submodules that
`network_metadata.nim` incbins, plus kzg:

- `vendor/mainnet`, `vendor/sepolia`, `vendor/hoodi`,
  `vendor/gnosis-chain-configs`, `vendor/glamsterdam-devnets`;
- `vendor/nim-kzg4844`, with `--recursive`. Its C sources are needed by the
  kzg wrapper.

Large LFS files are excluded with the same `lfs.fetchexclude` list nimbus-eth1
uses (`/public-keys/all.txt,/metadata/genesis.ssz,parsedConsensusGenesis.json`).

## 3. Makefile essentials (adapted from nimbus-eth1)

```make
BUILD_SYSTEM_DIR := vendor/nimbus-build-system
EXCLUDED_NIM_PACKAGES := $(wildcard vendor/nimbus-eth2/vendor/*)
-include $(BUILD_SYSTEM_DIR)/makefiles/variables.mk

GIT_SUBMODULE_CONFIG := -c lfs.fetchexclude=/public-keys/all.txt,/metadata/genesis.ssz,parsedConsensusGenesis.json
GIT_SUBMODULE_UPDATE := git -c submodule."vendor/nimbus-eth2".update=none submodule update --init --recursive; \
  git $(GIT_SUBMODULE_CONFIG) submodule update vendor/nimbus-eth2; \
  cd vendor/nimbus-eth2; \
  git $(GIT_SUBMODULE_CONFIG) submodule update --init vendor/mainnet vendor/sepolia vendor/hoodi \
      vendor/gnosis-chain-configs vendor/glamsterdam-devnets; \
  git $(GIT_SUBMODULE_CONFIG) submodule update --init --recursive vendor/nim-kzg4844; \
  cd ../..
```

Targets:

- `make update`: submodules and the Nim bootstrap.
- `make nimbu`, using `vendor/nimbus-eth2/scripts/compile_nim_program.sh`
  as nimbus-eth1 does.
- `make test`.
- `make lint`: exception headers, copyright year, vendor-sync check.

## 4. Keeping vendor pins in sync

There is one source of truth: the pinned `vendor/nimbus-eth2` commit.
`scripts/sync_vendor.sh` does the rest:

1. Reads `git -C vendor/nimbus-eth2 ls-tree HEAD vendor/` to get eth2's pinned
   commit for each library.
2. Checks out exactly that commit in our top-level `vendor/<lib>`.
3. With `--check`, fails if any pin differs. CI runs it in that mode.

Bumping nimbus-eth2:

1. Move `vendor/nimbus-eth2` to the new commit.
2. Run `scripts/sync_vendor.sh`.
3. Re-run the spec-version and line-number checks in [0003](0003-nimbus-eth2-reuse.md).
4. Commit everything together as `bump nimbus-eth2 to <sha>`.

## 5. As applied in M0

- **45 submodules:** `nimbus-eth2` @ `c3f68622` plus 44 libraries.
  `scripts/sync_vendor.sh` adds and pins them from eth2's `.gitmodules` and
  `ls-tree`, and `--check` verifies the pins.
- **How eth2 is kept out of `update-common`.** `GIT_SUBMODULE_CONFIG`
  carries `-c submodule.vendor/nimbus-eth2.update=none`, so the build
  system's recursive update skips eth2. `update-eth2`, which runs strictly
  after `update-common`, then initialises eth2 and only its data submodules
  plus `nim-kzg4844`.
- **Search path.** `env.sh` regenerates `nimbus-build-system.paths` (one
  `--path` per *top-level* `vendor/*` dir) on every invocation. eth2's nested
  vendors are therefore never on the Nim path. `EXCLUDED_NIM_PACKAGES` covers
  the legacy `.nimble` link mechanism.
- **Gotcha:** `make update` needs at least one commit in the repo
  (`GET_CURRENT_COMMIT_TIMESTAMP`). On a fresh `git init`, run `make deps`
  first or commit before `make update`.

## 6. Open points

- **Whether to vendor eth2 recursively instead.** That would mean using
  `vendor/nimbus-eth2/vendor/*` directly with no top-level copies. It is
  simpler to bump but fights nimbus-build-system's path generation, and it
  diverges from the eth1 precedent. Recommendation: keep the flat layout.
- **Disk and clone time.** A full update is a few GB because of the network
  config repos. A CI cache of `vendor/` is required.
