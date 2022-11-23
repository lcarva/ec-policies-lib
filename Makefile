SHELL := /bin/bash
REGO_IGNORES = --ignore '.*' --ignore node_modules --ignore antora
COVERAGE = @opa test . $(REGO_IGNORES) --threshold 100 2>&1 | sed -e '/^Code coverage/!d' -e 's/^/ERROR: /'; exit $${PIPESTATUS[0]}

POLICY_DIR=./policy

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

.PHONY: help
help: ## Display this help.
	@awk 'function ww(s) {\
		if (length(s) < 59) {\
			return s;\
		}\
		else {\
			r="";\
			l="";\
			split(s, arr, " ");\
			for (w in arr) {\
				if (length(l " " arr[w]) > 59) {\
					r=r l "\n                     ";\
					l="";\
				}\
				l=l " " arr[w];\
			}\
			r=r l;\
			return r;\
		}\
	} BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-18s\033[0m %s\n", "make " $$1, ww($$2) } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Development

.PHONY: test
test: ## Run all tests in verbose mode and check coverage
	@opa test . -v $(REGO_IGNORES)
	$(COVERAGE)

.PHONY: coverage
# The cat does nothing but avoids a non-zero exit code from grep -v
coverage: ## Show which lines of rego are not covered by tests
	@opa test . $(REGO_IGNORES) --coverage --format json | jq -r '.files | to_entries | map("\(.key): Uncovered:\(.value.not_covered)") | .[]' | grep -v "Uncovered:null" | cat

.PHONY: quiet-test
quiet-test: ## Run all tests in quiet mode and check coverage
	@opa test . $(REGO_IGNORES)
	$(COVERAGE)

# Do `dnf install entr` then run this a separate terminal or split window while hacking
.PHONY: live-test
live-test: ## Continuously run tests on changes to any `*.rego` files, `entr` needs to be installed
	@trap exit SIGINT; \
	while true; do \
	  git ls-files -c -o '*.rego' | entr -d -c $(MAKE) --no-print-directory quiet-test; \
	done

##
## Fixme: Currently conftest verify produces a error:
##   "rego_type_error: package annotation redeclared"
## In these two files:
##   policy/release/examples/time_based.rego
##   policy/lib/time_test.rego:1
## The error only appears when running the tests.
##
## Since the metadata support is a new feature in opa, it might be this
## is a bug that will go away in a future release of conftest. So for now
## we will ignore the error and not use conftest verify in the CI.
##
.PHONY: conftest-test
conftest-test: ## Run all tests with conftest instead of opa
	@conftest verify \
	  --policy $(POLICY_DIR)

.PHONY: fmt
fmt: ## Apply default formatting to all rego files. Use before you commit
	@opa fmt . --write

.PHONY: fmt-amend
fmt-amend: fmt ## Apply default formatting to all rego files then amend the current commit
	@git --no-pager diff $$(git ls-files '*.rego')
	@echo "Amend commit '$$(git log -n1 --oneline)' with the above diff?"
	@read -p "Hit enter to continue, Ctrl-C to abort."
	git add $$(git ls-files '*.rego')
	git commit --amend --no-edit

.PHONY: opa-check
opa-check: ## Check Rego files with strict mode (https://www.openpolicyagent.org/docs/latest/strict/)
	@opa check . --strict $(REGO_IGNORES)

##@ CI

.PHONY: fmt-check
fmt-check: ## Check formatting of Rego files
	@opa fmt . --list | xargs -r -n1 echo 'FAIL: Incorrect formatting found in'
	@opa fmt . --list --fail >/dev/null 2>&1

.PHONY: ci
ci: quiet-test opa-check fmt-check ## Runs all checks and tests

#--------------------------------------------------------------------

##@ Bundles TODO

# Pushes two bundles, one for release and one for policy.
# Each bundle includes policy/lib and its contents,
# which is why we need the temp dir and the extra copying.
# $(*) is expected to be either "release" or "pipeline".
#
.PHONY: push-bundles

BUNDLE_REPO=quay.io/hacbs-contract
BUNDLE_TAG=git-$(SHORT_SHA)

push-bundle-%:
	@export \
	  TMP_DIR="$$( mktemp -d -t ec-push.XXXXXXXXXX )" \
	  TARGET="$(BUNDLE_REPO)/ec-$(*)-policy:$(BUNDLE_TAG)" && \
	\
	mkdir $${TMP_DIR}/$(POLICY_DIR) && \
	\
	for d in lib $(*); do \
	  [[ -n $$( git status --porcelain $(POLICY_DIR)/$${d} ) ]] && \
	    echo "Aborting due to uncommitted changes in $(POLICY_DIR)/$${d}!" && \
	      exit 1; \
	  cp -r $(POLICY_DIR)/$${d} $${TMP_DIR}/$(POLICY_DIR)/$${d}; \
	done && \
	\
	echo "Pushing $(*) policies to $${TARGET}" && \
	conftest push $${TARGET} $${TMP_DIR} -p $(POLICY_DIR) && \
	\
	rm -rf $${TMP_DIR}

# Add the "latest" tag to policy bundles just pushed using the
# above. (Is there a better way to do that other than using
# skopeo copy..?)
#
bump-latest-%:
	@export \
	  TARGET="$(BUNDLE_REPO)/ec-$(*)-policy:$(BUNDLE_TAG)" \
	  LATEST="$(BUNDLE_REPO)/ec-$(*)-policy:latest" && \
	\
	echo "Copying $${TARGET} to $${LATEST}" && \
	skopeo copy --quiet docker://$${TARGET} docker://$${LATEST}


push-bundles: push-bundle-release push-bundle-pipeline ## Create and push policy bundles
bump-latest: bump-latest-release bump-latest-pipeline ## Update latest tag on pushed bundles

push-bump: push-bundles bump-latest ## Push policy bundles and update latest tag

#--------------------------------------------------------------------

##@ Utility

CONFTEST_VER=0.35.0
CONFTEST_SHA_Darwin_x86_64=bb407e9da8478dd4b84fc0dbe9121d67266a6023da376a5d81073a8b1b7b0794
CONFTEST_SHA_Darwin_arm64=a1dccd2118243f660fb244e62d3855ba68f476fc5928111422c406ad1ce65bae
CONFTEST_SHA_Linux_x86_64=f24414d7791db69c2c4937f29e7e6a1b057eebb1e8ecf69a47ea86901f9d9e71
CONFTEST_GOOS=$(shell go env GOOS | sed 's/./\u&/' )
CONFTEST_GOARCH=$(shell go env GOARCH | sed 's/amd64/x86_64/' )
CONFTEST_OS_ARCH=$(CONFTEST_GOOS)_$(CONFTEST_GOARCH)
CONFTEST_FILE=conftest_$(CONFTEST_VER)_$(CONFTEST_OS_ARCH).tar.gz
CONFTEST_URL=https://github.com/open-policy-agent/conftest/releases/download/v$(CONFTEST_VER)/$(CONFTEST_FILE)
CONFTEST_SHA=$(CONFTEST_SHA_${CONFTEST_OS_ARCH})
ifndef CONFTEST_BIN
  CONFTEST_BIN=$(HOME)/bin
endif
CONFTEST_DEST=$(CONFTEST_BIN)/conftest

.PHONY: install-conftest
install-conftest: ## Install `conftest` CLI from GitHub releases
	curl -s -L -O $(CONFTEST_URL)
	echo "$(CONFTEST_SHA) $(CONFTEST_FILE)" | sha256sum --check
	tar xzf $(CONFTEST_FILE) conftest
	@mkdir -p $(CONFTEST_BIN)
	mv conftest $(CONFTEST_DEST)
	chmod 755 $(CONFTEST_DEST)
	rm $(CONFTEST_FILE)

OPA_VER=v0.45.0
OPA_SHA_darwin_amd64=1d76713a65c11771bd86fe44d8ace17d79f1660e5bb00219d4f3c9b0f966f6e5
OPA_SHA_darwin_arm64_static=83d975213adbfe5721a4abf5b121ca1a66b6351bd569049282370a1a7393cbcb
OPA_SHA_linux_amd64_static=fb17d142d05c371e668440b414e41ccffc90c1e3d8f4984cf0c08e64fdd99a03
OPA_SHA_windows_amd64=31b12b954900584e8aa9103235adf192dd4c92e0039416eaec7d84e2f66fcf3e
OPA_OS_ARCH=$(shell go env GOOS)_$(shell go env GOARCH)
OPA_STATIC=$(if $(OPA_SHA_${OPA_OS_ARCH}_static),_static)
OPA_FILE=opa_$(OPA_OS_ARCH)$(OPA_STATIC)
OPA_URL=https://openpolicyagent.org/downloads/$(OPA_VER)/$(OPA_FILE)
OPA_SHA=$(OPA_SHA_${OPA_OS_ARCH}${OPA_STATIC})
ifndef OPA_BIN
  OPA_BIN=$(HOME)/bin
endif
OPA_DEST=$(OPA_BIN)/opa

.PHONY: install-opa
install-opa: ## Install `opa` CLI from GitHub releases
	curl -s -L -O $(OPA_URL)
	echo "$(OPA_SHA) $(OPA_FILE)" | sha256sum --check
	@mkdir -p $(OPA_BIN)
	cp $(OPA_FILE) $(OPA_DEST)
	chmod 755 $(OPA_DEST)
	rm $(OPA_FILE)

.PHONY: install-tools
install-tools: install-conftest install-opa ## Install all tools
