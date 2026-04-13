#!/usr/bin/env bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  cd "$REPO_ROOT"
}

@test "goal-init.sh passes bash syntax check" {
  run bash -n goal-init.sh
  [ "$status" -eq 0 ]
}

@test "goal-init.sh exists and is executable" {
  [ -f goal-init.sh ]
  [ -x goal-init.sh ]
}

@test "goal-init score prompt requires protocol-level probes for API contracts" {
  run grep -n "For transport- or API-facing requirements, probe the public interface" goal-init.sh
  [ "$status" -eq 0 ]
}

@test "req-system-prompt teaches protocol boundary acceptance criteria" {
  run grep -n "probe the network or protocol boundary rather than importing internals" req-system-prompt.md
  [ "$status" -eq 0 ]
}

@test "goal-init: exits 1 with usage when no args given" {
  run bash goal-init.sh
  [ "$status" -eq 1 ]
  [[ "$output" =~ "Usage: goal-init.sh" ]]
}

@test "goal-init: exits 1 when project path does not exist" {
  run bash goal-init.sh /nonexistent/path/xyz123
  [ "$status" -eq 1 ]
}

@test "goal-init: exits 1 with install message when repomix not on PATH" {
  run env PATH=/dev/null /bin/bash goal-init.sh "$BATS_TMPDIR"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "repomix not found" ]]
}

@test "json extractor: accepts raw JSON object" {
  result=$(echo '{"purpose":"test","capabilities":["a"]}' | python3 -c "
import sys, json, re
text = sys.stdin.read()
try:
    json.loads(text); print(text); sys.exit(0)
except Exception: pass
m = re.search(r'\{.*\}', text, re.DOTALL)
if m:
    try: json.loads(m.group()); print(m.group()); sys.exit(0)
    except Exception: pass
sys.exit(1)
")
  [ $? -eq 0 ]
  echo "$result" | python3 -c "import json,sys; json.loads(sys.stdin.read())"
}

@test "json extractor: extracts JSON from prose with markdown fences" {
  result=$(printf 'Here is the result:\n```json\n{"purpose":"test","capabilities":["a"]}\n```\nDone.' | python3 -c "
import sys, json, re
text = sys.stdin.read()
try:
    json.loads(text); print(text); sys.exit(0)
except Exception: pass
m = re.search(r'\{.*\}', text, re.DOTALL)
if m:
    try: json.loads(m.group()); print(m.group()); sys.exit(0)
    except Exception: pass
sys.exit(1)
")
  [ $? -eq 0 ]
}

@test "json extractor: exits 1 on unparseable text" {
  result=$(echo "This is just prose with no JSON" | python3 -c "
import sys, json, re
text = sys.stdin.read()
try:
    json.loads(text); print(text); sys.exit(0)
except Exception: pass
m = re.search(r'\{.*\}', text, re.DOTALL)
if m:
    try: json.loads(m.group()); print(m.group()); sys.exit(0)
    except Exception: pass
sys.exit(1)
" 2>/dev/null) && status=0 || status=1
  [ "$status" -eq 1 ]
}

@test "brief printer: formats all fields correctly" {
  result=$(python3 -c "
import json, sys
b = json.loads(sys.argv[1])
print('  Purpose:        ' + b.get('purpose', '(none)'))
print('  Capabilities:')
for i, c in enumerate(b.get('capabilities', []), 1):
    print(f'    {i}. {c}')
bs = b.get('broken_signals', [])
print('  Broken signals: ' + ('; '.join(bs) if bs else '(none)'))
gs = b.get('gaps', [])
print('  Gaps:           ' + ('; '.join(gs) if gs else '(none)'))
" '{"purpose":"Tracks things","capabilities":["store","retrieve"],"broken_signals":["items lost"],"gaps":["no export"]}')
  [[ "$result" =~ "Purpose:        Tracks things" ]]
  [[ "$result" =~ "1. store" ]]
  [[ "$result" =~ "Broken signals: items lost" ]]
}

@test "goal-brief.json edit path: invalid JSON is rejected" {
  result=$(echo "not valid json" | python3 -c "
import json, sys
try:
    json.loads(sys.stdin.read()); sys.exit(0)
except: sys.exit(1)
" 2>/dev/null) && status=0 || status=1
  [ "$status" -eq 1 ]
}

@test "provenance check: detects marker in GOAL.md" {
  echo -e "# Goal: Test\nsome content\n<!-- generated-by: goal-init.sh -->" \
    > "$BATS_TMPDIR/GOAL.md"
  run grep -q 'generated-by: goal-init.sh' "$BATS_TMPDIR/GOAL.md"
  [ "$status" -eq 0 ]
}

@test "provenance check: fails when marker absent from GOAL.md" {
  echo "# Goal: Test" > "$BATS_TMPDIR/GOAL.md"
  run grep -q 'generated-by: goal-init.sh' "$BATS_TMPDIR/GOAL.md"
  [ "$status" -eq 1 ]
}

@test "provenance check: detects marker in score.sh" {
  printf '#!/usr/bin/env bash\n# generated-by: goal-init.sh\necho 75\n' \
    > "$BATS_TMPDIR/score.sh"
  run grep -q 'generated-by: goal-init.sh' "$BATS_TMPDIR/score.sh"
  [ "$status" -eq 0 ]
}

@test "json validator: passes when all capability keys present and values are int 0..100" {
  brief='{"purpose":"test","capabilities":["Chain Control","Safety Gates"],"broken_signals":[],"gaps":[]}'
  json_out='{"score":80,"chain_control":80,"safety_gates":80}'
  echo "$brief" > "$BATS_TMPDIR/brief.json"
  run python3 - "$BATS_TMPDIR/brief.json" "$json_out" <<'PYEOF'
import sys, json
with open(sys.argv[1]) as f:
    brief = json.load(f)
out = json.loads(sys.argv[2])
assert 'score' in out
for k, v in out.items():
    assert isinstance(v, int) and 0 <= v <= 100, f'{k}={v!r} not int 0..100'
normalize = lambda c: c.lower().strip().replace(' ', '_')[:20]
expected = {normalize(c) for c in brief.get('capabilities', [])}
actual   = {normalize(k) for k in out.keys() if k != 'score'}
missing  = expected - actual
assert not missing, 'missing: ' + str(sorted(missing))
PYEOF
  [ "$status" -eq 0 ]
}

@test "json validator: fails when a capability key is missing" {
  brief='{"purpose":"test","capabilities":["Chain Control","Safety Gates"],"broken_signals":[],"gaps":[]}'
  json_out='{"score":80,"chain_control":80}'
  echo "$brief" > "$BATS_TMPDIR/brief.json"
  run python3 - "$BATS_TMPDIR/brief.json" "$json_out" <<'PYEOF'
import sys, json
with open(sys.argv[1]) as f:
    brief = json.load(f)
out = json.loads(sys.argv[2])
assert 'score' in out
for k, v in out.items():
    assert isinstance(v, int) and 0 <= v <= 100
normalize = lambda c: c.lower().strip().replace(' ', '_')[:20]
expected = {normalize(c) for c in brief.get('capabilities', [])}
actual   = {normalize(k) for k in out.keys() if k != 'score'}
missing  = expected - actual
assert not missing, 'missing: ' + str(sorted(missing))
PYEOF
  [ "$status" -eq 1 ]
}

@test "json validator: fails when a value is a string not int" {
  brief='{"purpose":"test","capabilities":["Chain Control"],"broken_signals":[],"gaps":[]}'
  json_out='{"score":"80","chain_control":"80"}'
  echo "$brief" > "$BATS_TMPDIR/brief.json"
  run python3 - "$BATS_TMPDIR/brief.json" "$json_out" <<'PYEOF'
import sys, json
with open(sys.argv[1]) as f:
    brief = json.load(f)
out = json.loads(sys.argv[2])
assert 'score' in out
for k, v in out.items():
    assert isinstance(v, int) and 0 <= v <= 100, f'{k}={v!r} not int 0..100'
normalize = lambda c: c.lower().strip().replace(' ', '_')[:20]
expected = {normalize(c) for c in brief.get('capabilities', [])}
actual   = {normalize(k) for k in out.keys() if k != 'score'}
missing  = expected - actual
assert not missing
PYEOF
  [ "$status" -eq 1 ]
}

@test "capability key normalization: lowercases, underscores spaces, truncates to 20" {
  result=$(python3 -c "
caps = ['Chain Control', 'Safety Gates', 'A Very Long Capability Name That Exceeds Twenty']
normalize = lambda c: c.lower().strip().replace(' ', '_')[:20]
for c in caps:
    print(normalize(c))
")
  [[ "$result" =~ "chain_control" ]]
  [[ "$result" =~ "safety_gates" ]]
  [[ "$result" =~ "a_very_long_capabili" ]]
}

# ── setup.sh integration block tests ─────────────────────────────────────────

_run_detection_block() {
  local proj="$1"
  PROJECT_PATH="$proj" bash -c '
    GOAL_ACTION=create
    _has_goal=false; _has_score=false
    [ -f "$PROJECT_PATH/GOAL.md"  ] && _has_goal=true
    [ -f "$PROJECT_PATH/score.sh" ] && _has_score=true
    if $_has_goal && $_has_score; then
      _goal_ok=false; _score_ok=false
      grep -q "generated-by: goal-init.sh" "$PROJECT_PATH/GOAL.md"  2>/dev/null && _goal_ok=true
      grep -q "generated-by: goal-init.sh" "$PROJECT_PATH/score.sh" 2>/dev/null && _score_ok=true
      if $_goal_ok && $_score_ok; then
        _plain=$(bash "$PROJECT_PATH/score.sh" 2>/dev/null || true)
        _json=$(bash  "$PROJECT_PATH/score.sh" --json 2>/dev/null || true)
        _brief="$PROJECT_PATH/.goal-brief.json"
        if echo "$_plain" | grep -qE "^[0-9]+$" && \
           python3 - "$_brief" "$_json" 2>/dev/null <<'"'"'PYEOF'"'"'
import json, sys, os
brief_path, json_out = sys.argv[1], sys.argv[2]
out = json.loads(json_out)
assert isinstance(out.get("score"), int), "score not int"
assert os.path.exists(brief_path), "brief not found — run goal-init.sh again"
with open(brief_path) as f:
    brief = json.load(f)
normalize = lambda c: c.lower().strip().replace(" ", "_")[:20]
expected = {normalize(c) for c in brief.get("capabilities", [])}
actual   = {normalize(k) for k in out.keys() if k != "score"}
missing  = expected - actual
assert not missing, "missing keys: " + str(sorted(missing))
PYEOF
        then
          GOAL_ACTION=keep
        fi
      fi
    elif $_has_goal && ! $_has_score; then
      GOAL_ACTION=create
    elif ! $_has_goal && $_has_score; then
      GOAL_ACTION=create
    fi
    echo "$GOAL_ACTION"
  ' PROJECT_PATH="$proj"
}

@test "setup.sh block: both files with valid provenance + brief → GOAL_ACTION=keep" {
  mkdir -p "$BATS_TMPDIR/proj_keep"
  printf '# Goal: Test\n<!-- generated-by: goal-init.sh -->\n' \
    > "$BATS_TMPDIR/proj_keep/GOAL.md"
  printf '#!/usr/bin/env bash\n# generated-by: goal-init.sh\n[[ "${1:-}" == "--json" ]] && echo '"'"'{"score":75,"chain_control":75}'"'"' || echo 75\n' \
    > "$BATS_TMPDIR/proj_keep/score.sh"
  chmod +x "$BATS_TMPDIR/proj_keep/score.sh"
  printf '{"purpose":"test","capabilities":["Chain Control"],"broken_signals":[],"gaps":[]}\n' \
    > "$BATS_TMPDIR/proj_keep/.goal-brief.json"
  result=$(_run_detection_block "$BATS_TMPDIR/proj_keep")
  [ "$result" = "keep" ]
}

@test "setup.sh block: stale score.sh missing cap key → GOAL_ACTION stays create" {
  mkdir -p "$BATS_TMPDIR/proj_stale"
  printf '# Goal: Test\n<!-- generated-by: goal-init.sh -->\n' \
    > "$BATS_TMPDIR/proj_stale/GOAL.md"
  printf '#!/usr/bin/env bash\n# generated-by: goal-init.sh\n[[ "${1:-}" == "--json" ]] && echo '"'"'{"score":75}'"'"' || echo 75\n' \
    > "$BATS_TMPDIR/proj_stale/score.sh"
  chmod +x "$BATS_TMPDIR/proj_stale/score.sh"
  printf '{"purpose":"test","capabilities":["Chain Control","Safety Gates"],"broken_signals":[],"gaps":[]}\n' \
    > "$BATS_TMPDIR/proj_stale/.goal-brief.json"
  result=$(_run_detection_block "$BATS_TMPDIR/proj_stale")
  [ "$result" != "keep" ]
}

@test "setup.sh block: GOAL.md only (no score.sh) → GOAL_ACTION=create" {
  mkdir -p "$BATS_TMPDIR/proj_partial"
  echo "# Goal: Test" > "$BATS_TMPDIR/proj_partial/GOAL.md"
  rm -f "$BATS_TMPDIR/proj_partial/score.sh"
  result=$(_run_detection_block "$BATS_TMPDIR/proj_partial")
  [ "$result" = "create" ]
}

@test "setup.sh block: score.sh only (no GOAL.md) → GOAL_ACTION=create" {
  mkdir -p "$BATS_TMPDIR/proj_score_only"
  rm -f "$BATS_TMPDIR/proj_score_only/GOAL.md"
  printf '#!/usr/bin/env bash\necho 50\n' > "$BATS_TMPDIR/proj_score_only/score.sh"
  chmod +x "$BATS_TMPDIR/proj_score_only/score.sh"
  result=$(_run_detection_block "$BATS_TMPDIR/proj_score_only")
  [ "$result" = "create" ]
}

@test "setup.sh block: valid provenance + score but no brief → GOAL_ACTION stays create" {
  mkdir -p "$BATS_TMPDIR/proj_no_brief"
  printf '# Goal: Test\n<!-- generated-by: goal-init.sh -->\n' \
    > "$BATS_TMPDIR/proj_no_brief/GOAL.md"
  printf '#!/usr/bin/env bash\n# generated-by: goal-init.sh\n[[ "${1:-}" == "--json" ]] && echo '"'"'{"score":75}'"'"' || echo 75\n' \
    > "$BATS_TMPDIR/proj_no_brief/score.sh"
  chmod +x "$BATS_TMPDIR/proj_no_brief/score.sh"
  rm -f "$BATS_TMPDIR/proj_no_brief/.goal-brief.json"
  result=$(_run_detection_block "$BATS_TMPDIR/proj_no_brief")
  [ "$result" != "keep" ]
}

@test "setup.sh block: both files but no provenance markers → GOAL_ACTION stays create (no auto-keep)" {
  mkdir -p "$BATS_TMPDIR/proj_no_prov"
  echo "# Goal: Generic" > "$BATS_TMPDIR/proj_no_prov/GOAL.md"
  printf '#!/usr/bin/env bash\necho 50\n' > "$BATS_TMPDIR/proj_no_prov/score.sh"
  chmod +x "$BATS_TMPDIR/proj_no_prov/score.sh"
  result=$(_run_detection_block "$BATS_TMPDIR/proj_no_prov")
  [ "$result" != "keep" ]
}
