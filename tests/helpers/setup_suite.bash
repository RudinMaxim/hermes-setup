# shellcheck shell=bash

export REPO_ROOT
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

export LIB="$REPO_ROOT/scripts/lib"
export SCRIPTS="$REPO_ROOT/scripts"
