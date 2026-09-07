#!/usr/bin/env bash
# Regression tests for the pinned shared no-mistakes gate action.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACTION_REF=32d396ac0f29135daf7fcb9964aba9d5f4e796d6
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-required)
VERIFY="$TMP_ROOT/verify.py"
OLD_SHA=1111111111111111111111111111111111111111
NEW_SHA=2222222222222222222222222222222222222222
SIGNATURE='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
COMPLETED_STEPS='[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]'

fetch_shared_verifier() {
  command -v curl >/dev/null 2>&1 || fail "curl is required to exercise the pinned shared action"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to exercise the pinned shared action"
  curl --fail --silent --show-error --location \
    "https://raw.githubusercontent.com/kunchenguid/no-mistakes/${ACTION_REF}/.github/actions/require-no-mistakes/verify.py" \
    > "$VERIFY" || fail "could not fetch the pinned shared action verifier"
  [ -s "$VERIFY" ] || fail "the pinned shared action verifier was empty"
}

run_verifier() {
  local body=$1 head=$2
  PR_BODY="$body" PR_HEAD_SHA="$head" PR_AUTHOR=regression PR_NUMBER=3006 \
    python3 "$VERIFY" 2>&1
}

test_matching_head_and_completed_steps_pass() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$NEW_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  expect_code 0 "$rc" "shared action rejected an attestation bound to the current PR head"
  assert_contains "$output" "Found structurally compliant pipeline step attestation." \
    "shared action did not report the matching attestation as compliant"
  pass "shared action accepts a matching head_sha with completed required steps"
}

test_mismatched_head_fails_with_both_shas() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$OLD_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation from a different PR head"
  assert_contains "$output" "$OLD_SHA" \
    "mismatched-head failure did not name the attestation head SHA"
  assert_contains "$output" "$NEW_SHA" \
    "mismatched-head failure did not name the actual PR head SHA"
  pass "shared action rejects a mismatched head_sha and names both SHAs"
}

test_missing_head_fails() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation without head_sha"
  assert_contains "$output" "structured pipeline step attestation" \
    "missing-head failure did not explain that the attestation is invalid"
  pass "shared action rejects an attestation with no head_sha"
}

test_body_refresh_recovers_event_check_without_changing_head() {
  local event output rc
  # Exercise the GitHub event JSON interface used when action PR inputs are empty.
  python3 - "$TMP_ROOT" "$SIGNATURE" "$COMPLETED_STEPS" "$OLD_SHA" "$NEW_SHA" <<'PY'
import json
import pathlib
import sys

root, signature, steps, old, head = sys.argv[1:]
for action, attested in (("synchronize", old), ("edited", head)):
    attestation = json.dumps({"head_sha": attested, "steps": json.loads(steps)})
    payload = {"action": action, "pull_request": {
        "number": 3006, "head": {"sha": head, "ref": "regression"},
        "user": {"login": "regression"},
        "body": signature + "\n<!-- no-mistakes-pipeline-attestation:v1 " + attestation + " -->",
    }}
    pathlib.Path(root, action + ".json").write_text(json.dumps(payload), encoding="utf-8")
PY
  # A refreshed body passes in a new event; replaying the old event still fails.
  for event in synchronize edited synchronize; do
    rc=0
    output=$(PR_BODY='' PR_HEAD_SHA='' PR_HEAD_REF='' PR_AUTHOR='' PR_NUMBER='' \
      NM_EXEMPT_AUTHORS='' NM_EXEMPT_HEAD_BRANCHES='' NM_EXEMPT_BOT_AUTHORS=false \
      GITHUB_EVENT_PATH="$TMP_ROOT/$event.json" GITHUB_OUTPUT='' \
      python3 "$VERIFY" 2>&1) || rc=$?
    if [ "$event" = edited ]; then
      expect_code 0 "$rc" "refreshed event attestation did not recover the check"
      assert_contains "$output" "Found structurally compliant pipeline step attestation." \
        "refreshed event did not produce a compliant verdict"
    else
      expect_code 1 "$rc" "stale event passed without refreshing its attestation"
      assert_contains "$output" "attestation.head_sha: $OLD_SHA" "stale attestation was not diagnosed"
      assert_contains "$output" "PR head: $NEW_SHA" "event did not retain the actual PR head"
    fi
  done
  pass "body refresh recovers the event check while stale event replay remains rejected"
}

test_ci_fix_push_requires_refreshed_event_attestation() {
  # Exercise the action's default GitHub event input and GITHUB_OUTPUT contract.
  # A CI auto-fix advances the head before the publisher refreshes the PR body.
  python3 - "$VERIFY" "$TMP_ROOT" "$SIGNATURE" "$COMPLETED_STEPS" "$OLD_SHA" "$NEW_SHA" <<'PY' \
    || fail "CI-fix publication sequence violated the commit-bound attestation contract"
import json
import os
from pathlib import Path
import subprocess
import sys

verifier, root, signature, steps, old, new = sys.argv[1:]
event = Path(root) / "pull_request.json"
output = Path(root) / "action-output"
env = {key: value for key, value in os.environ.items()
       if not key.startswith(("PR_", "NM_EXEMPT_"))}
env.update(GITHUB_EVENT_PATH=str(event), GITHUB_OUTPUT=str(output))
for label, head, attested, expected in (
    ("initial publication", old, old, 0),
    ("CI-fix push with stale body", new, old, 1),
    ("publisher refresh after CI fix", new, new, 0),
):
    body = signature + "\n<!-- no-mistakes-pipeline-attestation:v1 " + json.dumps({
        "head_sha": attested, "steps": json.loads(steps),
    }) + " -->"
    event.write_text(json.dumps({"action": "synchronize" if head != attested else "edited",
                                "pull_request": {"number": 4, "body": body,
                                                 "head": {"sha": head},
                                                 "user": {"login": "regression"}}}),
                     encoding="utf-8")
    output.write_text("", encoding="utf-8")
    result = subprocess.run([sys.executable, verifier], env=env,
                            capture_output=True, text=True)
    assert result.returncode == expected, (label, result.stdout, result.stderr)
    fields = dict(line.split("=", 1) for line in output.read_text().splitlines())
    assert fields["compliant"] == ("true" if expected == 0 else "false"), (label, fields)
    assert fields["exempt"] == "false", (label, fields)
    if expected:
        assert old in result.stderr and new in result.stderr, result.stderr
PY
  pass "CI-fix push fails until the event carries a refreshed head-bound attestation"
}

fetch_shared_verifier
test_matching_head_and_completed_steps_pass
test_mismatched_head_fails_with_both_shas
test_missing_head_fails
test_body_refresh_recovers_event_check_without_changing_head
test_ci_fix_push_requires_refreshed_event_attestation
