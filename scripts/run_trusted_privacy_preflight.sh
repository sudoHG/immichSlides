#!/bin/sh
set -eu

: "${PRIVACY_BASE_SHA:?PRIVACY_BASE_SHA is required}"
: "${PRIVACY_HEAD_SHA:?PRIVACY_HEAD_SHA is required}"

test "$(git rev-parse HEAD)" = "$PRIVACY_BASE_SHA"
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_git_privacy_gate.py
test "$(git rev-parse HEAD)" = "$PRIVACY_BASE_SHA"
python3 scripts/git_privacy_gate.py \
    --range "${PRIVACY_BASE_SHA}..${PRIVACY_HEAD_SHA}"
test "$(git rev-parse HEAD)" = "$PRIVACY_BASE_SHA"
