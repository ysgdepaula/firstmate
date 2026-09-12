#!/usr/bin/env bash
# Regression tests for the pinned shared no-mistakes gate action.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACTION_REF=76fa0921a9797b09e120c8b5979c4d0e65f88922
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

test_live_pr_state_overrides_archived_event() {
  # Execute the pinned verifier against its HTTP and GitHub output interfaces.
  # The parsed workflow is the executable configuration contract under test.
  ruby -ryaml -rjson -e 'puts JSON.generate(YAML.load_file(ARGV.fetch(0)))' \
    "$ROOT/.github/workflows/no-mistakes-required.yml" > "$TMP_ROOT/workflow.json" \
    || fail "could not parse the compliance workflow"
  python3 - "$VERIFY" "$TMP_ROOT" "$SIGNATURE" "$COMPLETED_STEPS" "$OLD_SHA" "$NEW_SHA" "$ACTION_REF" <<'PYTEST' \
    || fail "live PR attestation contract failed"
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
from threading import Thread

verifier, root, signature, steps, old, new, action_ref = sys.argv[1:]
event = Path(root) / "pull_request.json"
output = Path(root) / "action-output"
requests = []
response = {}
status = 200

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        requests.append((self.path, self.headers.get("Authorization")))
        self.send_response(status)
        self.end_headers()
        self.wfile.write(json.dumps(response).encode())

    def log_message(self, *args):
        pass

def pr(head, attested, completed=True):
    records = json.loads(steps)
    if not completed:
        records[0]["status"] = "skipped"
    body = signature + "\n<!-- no-mistakes-pipeline-attestation:v1 " + json.dumps({
        "head_sha": attested, "steps": records,
    }) + " -->"
    return {"number": 4, "body": body, "head": {"sha": head, "ref": "regression"},
            "user": {"login": "regression"}}

server = HTTPServer(("127.0.0.1", 0), Handler)
thread = Thread(target=server.serve_forever, daemon=True)
thread.start()
env = {key: value for key, value in os.environ.items()
       if not key.startswith(("PR_", "NM_EXEMPT_", "GITHUB_"))}
env.update(GITHUB_EVENT_PATH=str(event), GITHUB_OUTPUT=str(output),
           GITHUB_TOKEN="fixture-token", GITHUB_REPOSITORY="fixture/firstmate",
           GITHUB_API_URL=f"http://127.0.0.1:{server.server_port}")
try:
    for label, archived, live, http_status, expected, diagnostic in (
        # Keep the same archived event through a CI-fix publication cycle.
        # The live body must be republished after the fix advances the head;
        # replaying the event alone cannot recover the failed check.
        ("before CI fix push", pr(old, old), pr(old, old), 200, 0,
         "Found structurally compliant"),
        ("CI fix pushed without attestation refresh", pr(old, old), pr(new, old), 200, 1,
         "head_sha does not match"),
        ("rerun before attestation refresh", pr(old, old), pr(new, old), 200, 1,
         "head_sha does not match"),
        ("same event after attestation refresh", pr(old, old), pr(new, new), 200, 0,
         "Found structurally compliant"),
        ("rerun after body refresh", pr(new, old), pr(new, new), 200, 0,
         "Found structurally compliant"),
        ("push before body refresh", pr(new, old), pr(new, old), 200, 1,
         "head_sha does not match"),
        ("old green event after new push", pr(old, old), pr(new, old), 200, 1,
         "head_sha does not match"),
        ("live skipped review", pr(old, old), pr(new, new, False), 200, 1,
         "review (status=skipped)"),
        ("denied API with green archived event", pr(old, old), {}, 403, 1,
         "Could not verify this PR's live body/head"),
        ("malformed API with green archived event", pr(old, old), {}, 200, 1,
         "Could not verify this PR's live body/head"),
    ):
        event.write_text(json.dumps({"action": "synchronize", "pull_request": archived}),
                         encoding="utf-8")
        output.write_text("", encoding="utf-8")
        response, status = live, http_status
        requests.clear()
        result = subprocess.run([sys.executable, verifier], env=env,
                                capture_output=True, text=True, timeout=20)
        assert result.returncode == expected, (label, result.stdout, result.stderr)
        assert diagnostic in result.stdout + result.stderr, (label, result)
        assert requests == [("/repos/fixture/firstmate/pulls/4", "Bearer fixture-token")], (label, requests)
        fields = dict(line.split("=", 1) for line in output.read_text().splitlines())
        assert fields["compliant"] == ("true" if expected == 0 else "false"), (label, fields)
        assert fields["exempt"] == "false", (label, fields)

    # Execute the workflow's bounded retry sequence with the actual verifier.
    # Only sleep is replaced: publication advances at that boundary, with no
    # real-time scheduling dependency or GitHub writes in this regression.
    workflow = json.loads((Path(root) / "workflow.json").read_text())
    sequence = workflow["jobs"]["check"]["steps"]
    action = f"kunchenguid/no-mistakes/.github/actions/require-no-mistakes@{action_ref}"
    fakebin = Path(root) / "fakebin"
    fakebin.mkdir()
    sleeper = fakebin / "sleep"
    sleeper.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$SLEEP_LOG"\n')
    sleeper.chmod(0o755)
    sleep_log = Path(root) / "sleep-log"
    delay_env = dict(env, PATH=str(fakebin) + os.pathsep + env["PATH"],
                     SLEEP_LOG=str(sleep_log))
    for label, initial, published, published_status, expected, count in (
        ("already current", pr(new, new), pr(new, new), 200, 0, 1),
        ("publication catches up", pr(new, old), pr(new, new), 200, 0, 2),
        ("publication remains stale", pr(new, old), pr(new, old), 200, 1, 2),
        ("publication skips review", pr(new, old), pr(new, new, False), 200, 1, 2),
        ("retry API fails", pr(new, old), {}, 403, 1, 2),
        ("head advances again", pr(new, old), pr("3" * 40, new), 200, 1, 2),
    ):
        event.write_text(json.dumps({"action": "synchronize", "pull_request": initial}))
        output.write_text("")
        sleep_log.write_text("")
        response, status = initial, 200
        requests.clear()
        outcomes = {}
        job_exit = 0
        for step in sequence:
            # Interpret only the small expression subset used by this workflow;
            # fail loudly if the declarative contract gains unsupported syntax.
            if "if" in step:
                reference, operator, value = shlex.split(step["if"])
                scope, identifier, field = reference.split(".")
                assert scope == "steps" and operator == "=="
                assert field in ("outcome", "conclusion")
                if outcomes[identifier][field] != value:
                    continue
            if "uses" in step:
                assert step["uses"] == action, "must execute the pinned verifier"
                assert not step.get("with"), "verification must use live facts"
                output.write_text("")
                result = subprocess.run([sys.executable, verifier], env=env,
                                        capture_output=True, text=True, timeout=20)
            else:
                assert shlex.split(step["run"]) == ["sleep", "60"]
                result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", step["run"]],
                                        env=delay_env, capture_output=True, text=True, timeout=5)
                response, status = published, published_status
            outcome = "success" if result.returncode == 0 else "failure"
            tolerated = step.get("continue-on-error", False)
            if "id" in step:
                outcomes[step["id"]] = {
                    "outcome": outcome, "conclusion": "success" if tolerated else outcome,
                }
            if result.returncode != 0 and not tolerated:
                job_exit = result.returncode
                break
        assert job_exit == expected, (label, result.stdout, result.stderr)
        assert len(requests) == count, (label, requests)
        assert sleep_log.read_text().splitlines() == (["60"] if count == 2 else []), label
        fields = dict(line.split("=", 1) for line in output.read_text().splitlines())
        assert fields["compliant"] == ("true" if expected == 0 else "false"), (label, fields)
        print(f"ok - workflow {label}: {count} verification attempt(s), exit {expected}")
finally:
    server.shutdown()
    thread.join()
    server.server_close()
PYTEST
  pass "live PR refresh recovers stale events; stale heads, skipped steps, and API failures are rejected"
}

fetch_shared_verifier
test_matching_head_and_completed_steps_pass
test_mismatched_head_fails_with_both_shas
test_missing_head_fails
test_live_pr_state_overrides_archived_event
