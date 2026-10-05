# nimbu
# Copyright (c) 2026 Agnish Ghosh
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Adapted from the nimbus-eth1 / nimbus-eth2 Makefiles - see
# notes/0004-repo-layout-and-vendoring.md

SHELL := bash # the shell used internally by "make"

# used inside the included makefiles
BUILD_SYSTEM_DIR := vendor/nimbus-build-system

# nimbus-eth2's own nested copies of our dependencies must not be picked up
EXCLUDED_NIM_PACKAGES := $(wildcard vendor/nimbus-eth2/vendor/*)

# we set its default value before LOG_LEVEL is used in "variables.mk"
LOG_LEVEL := TRACE

# - "vendor/hoodi" etc. exceed GitHub's LFS quota and we don't need those files
# - nimbus-eth2's submodules are initialised selectively, see "update-eth2"
# MSYS_NO_PATHCONV=1: On Windows MSYS2, 1st path gets mangled without this flag!
GIT_SUBMODULE_ENV := MSYS_NO_PATHCONV=1
GIT_SUBMODULE_LFS_CONFIG := -c lfs.fetchexclude=/public-keys/all.txt,/metadata/genesis.ssz,parsedConsensusGenesis.json
GIT_SUBMODULE_CONFIG := $(GIT_SUBMODULE_LFS_CONFIG) -c submodule.vendor/nimbus-eth2.update=none

# network configs that nimbus-eth2's `network_metadata.nim` embeds at compile time
ETH2_DATA_SUBMODULES := \
	vendor/mainnet \
	vendor/sepolia \
	vendor/hoodi \
	vendor/gnosis-chain-configs \
	vendor/glamsterdam-devnets

# we don't want an error here, so we can handle things later, in the ".DEFAULT" target
-include $(BUILD_SYSTEM_DIR)/makefiles/variables.mk

TOOLS := \
	nimbu
TOOLS_DIRS := \
	nimbu
TOOLS_CSV := $(subst $(SPACE),$(COMMA),$(TOOLS))

.PHONY: \
	all \
	deps \
	update \
	update-eth2 \
	test \
	lint \
	clean \
	$(TOOLS)

ifeq ($(NIM_PARAMS),)
# "variables.mk" was not included, so we update the submodules.
GIT_SUBMODULE_UPDATE := \
	$(GIT_SUBMODULE_ENV) git $(GIT_SUBMODULE_CONFIG) submodule update --init --recursive && \
	$(GIT_SUBMODULE_ENV) git $(GIT_SUBMODULE_LFS_CONFIG) submodule update --init vendor/nimbus-eth2 && \
	$(GIT_SUBMODULE_ENV) git -C vendor/nimbus-eth2 $(GIT_SUBMODULE_LFS_CONFIG) submodule update --init $(ETH2_DATA_SUBMODULES) && \
	$(GIT_SUBMODULE_ENV) git -C vendor/nimbus-eth2 $(GIT_SUBMODULE_LFS_CONFIG) submodule update --init --recursive vendor/nim-kzg4844
.DEFAULT:
	+@ echo -e "Git submodules not found. Running '$(GIT_SUBMODULE_UPDATE)'.\n"; \
		$(GIT_SUBMODULE_UPDATE) && \
		echo
# Now that the included *.mk files appeared, and are newer than this file, Make will restart itself:
# https://www.gnu.org/software/make/manual/make.html#Remaking-Makefiles
#
# After restarting, it will execute its original goal, so we don't have to start a child Make here
# with "$(MAKE) $(MAKECMDGOALS)". Isn't hidden control flow great?

else # "variables.mk" was included. Business as usual until the end of this file.

# default target, because it's the first one that doesn't start with '.'
all: | $(TOOLS)

# must be included after the default target
-include $(BUILD_SYSTEM_DIR)/makefiles/targets.mk

#- "--define:release" cannot be added to "config.nims"
#- disable Nim's default parallelisation because it starts too many processes for too little gain
NIM_PARAMS := -d:release --parallelBuild:1 $(NIM_PARAMS)

ifeq ($(USE_LIBBACKTRACE), 0)
NIM_PARAMS += -d:disable_libbacktrace
endif

BUILD_END_MSG := "\\x1B[92mBuild completed successfully:\\x1B[39m"

deps: | deps-common build/generate_makefile

# Build the generate_makefile tool which turns Nim compilation into a
# two-step process (nim c --compileOnly → generate_makefile → sub-make)
build/generate_makefile: vendor/nimbus-eth2/tools/generate_makefile.nim | deps-common
	+ echo -e $(BUILD_MSG) "$@" && \
		$(ENV_SCRIPT) $(NIMC) c -o:$@ $(NIM_PARAMS) --skipParentCfg vendor/nimbus-eth2/tools/generate_makefile.nim && \
		echo -e $(BUILD_END_MSG) "$@"

#- nimbus-eth2 is skipped by "update-common" (see GIT_SUBMODULE_CONFIG) so that
#  its full, recursive submodule tree is never fetched; only the parts we
#  compile against are initialised here
update-eth2: | update-common
	$(GIT_SUBMODULE_ENV) git $(GIT_SUBMODULE_LFS_CONFIG) submodule update --init vendor/nimbus-eth2
	$(GIT_SUBMODULE_ENV) git -C vendor/nimbus-eth2 $(GIT_SUBMODULE_LFS_CONFIG) submodule update --init $(ETH2_DATA_SUBMODULES)
	$(GIT_SUBMODULE_ENV) git -C vendor/nimbus-eth2 $(GIT_SUBMODULE_LFS_CONFIG) submodule update --init --recursive vendor/nim-kzg4844

#- deletes binaries that might need to be rebuilt after a Git pull
update: | update-eth2
	rm -f build/generate_makefile
	rm -fr nimcache/

# builds the tools, wherever they are
$(TOOLS): | build deps
	+ for D in $(TOOLS_DIRS); do [ -e "$${D}/$@.nim" ] && TOOL_DIR="$${D}" && break; done && \
		echo -e $(BUILD_MSG) "build/$@" && \
		MAKE="$(MAKE)" V="$(V)" $(ENV_SCRIPT) vendor/nimbus-eth2/scripts/compile_nim_program.sh \
		$@ "$${TOOL_DIR}/$@.nim" $(NIM_PARAMS) && \
		echo -e $(BUILD_END_MSG) "build/$@"

# Tests are silent by default; `make test TEST_LOG=1` writes a JSON log file
# per test module (e.g. `test_chain_follower.log`) for debugging
ifeq ($(TEST_LOG), 1)
TEST_LOG_PARAMS := -d:chronicles_sinks=json[file]
else
TEST_LOG_PARAMS := -d:chronicles_log_level=NONE
endif

all_tests: | build deps
	+ echo -e $(BUILD_MSG) "build/$@" && \
		MAKE="$(MAKE)" V="$(V)" $(ENV_SCRIPT) vendor/nimbus-eth2/scripts/compile_nim_program.sh \
		$@ "tests/$@.nim" $(NIM_PARAMS) $(TEST_LOG_PARAMS) && \
		echo -e $(BUILD_END_MSG) "build/$@"

test: | all_tests
	build/all_tests $(TEST_ARGS)

lint:
	scripts/check_exception_headers.sh
	scripts/check_copyright_year.sh
	scripts/sync_vendor.sh --check

clean: | clean-common
	rm -rf build/{$(TOOLS_CSV),all_tests,generate_makefile}

endif # "variables.mk" was not included
