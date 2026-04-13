#!/usr/bin/env bash
# goal-init.sh — Requirements-first GOAL.md + score.sh generator
#
# Usage: goal-init.sh <project-path>
#
# Phase 0: Preflight — require REQUIREMENTS.md, validate schema
# Phase 1: Gap analysis — AI determines passing/failing status per REQ
# Phase 2: Generate score.sh — one probe per REQ
# Phase 3: Generate GOAL.md — action catalog for failing REQs only
set -euo pipefail

if [ -f ~/.secrets ]; then source ~/.secrets 2>/dev/null || true; fi
if [ -z "${OR_KEY:-}" ] && [ -n "${OPENROUTER_API_KEY:-}" ]; then
  OR_KEY="$OPENROUTER_API_KEY"
fi
_HEPH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_HEPH_DIR/.env" ]; then source "$_HEPH_DIR/.env" 2>/dev/null || true; fi
if [ -z "${OR_KEY:-}" ] && [ -n "${OPENROUTER_API_KEY:-}" ]; then
  OR_KEY="$OPENROUTER_API_KEY"
fi
export OR_KEY GEN_MODEL
GEN_MODEL="${GEN_MODEL:-${WORKER_MODEL:-minimax/minimax-m2.7}}"

hr()  { echo ""; echo "────────────────────────────────────────────────"; }
hdr() { hr; echo " $*"; hr; }
ok()  { echo "  ✓ $*"; }
err() { echo "  ✗ $*" >&2; }
ask() { printf "  %s: " "$1"; read -r "$2"; }

PROJECT_PATH="${1:-}"
[ -z "$PROJECT_PATH" ] && { err "Usage: goal-init.sh <project-path>"; exit 1; }
[ -d "$PROJECT_PATH" ] || { err "Not a directory: $PROJECT_PATH"; exit 1; }
PROJECT_PATH="$(cd "$PROJECT_PATH" && pwd)"
PROJECT_NAME="$(basename "$PROJECT_PATH")"
REQ_FILE="$PROJECT_PATH/REQUIREMENTS.md"

command -v repomix &>/dev/null || {
  err "repomix not found. Install: npm install -g repomix"
  exit 1
}

ai_run_prompt() {
  local _prompt="$1"
  printf '%s' "$_prompt" | python3 -c "
import json, sys, urllib.request, os
prompt = sys.stdin.read()
key    = os.environ.get('OR_KEY', '')
model  = os.environ.get('GEN_MODEL', '')
base   = os.environ.get('OR_BASE_URL', 'https://openrouter.ai/api/v1')
if not key:
    print('ERROR: OR_KEY not set', file=sys.stderr); sys.exit(1)
data = json.dumps({'model': model, 'messages': [{'role': 'user', 'content': prompt}]}).encode()
req  = urllib.request.Request(base + '/chat/completions', data=data,
         headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
try:
    r = json.loads(urllib.request.urlopen(req, timeout=120).read())
    print(r['choices'][0]['message']['content'])
except urllib.error.HTTPError as e:
    print('HTTP ' + str(e.code) + ': ' + e.read().decode()[:300], file=sys.stderr); sys.exit(1)
except Exception as e:
    print('ERROR: ' + str(e), file=sys.stderr); sys.exit(1)
"
}

_extract_json() {
  python3 -c "
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
" 2>/dev/null
}

_parse_reqs() {
  python3 - "$REQ_FILE" << 'PYEOF'
import sys, re, json

with open(sys.argv[1]) as f:
    content = f.read()

reqs = []
pattern = re.compile(
    r'##\s+(REQ-(\d+)):\s*([^\n]+)\n(.*?)(?=\n##\s+REQ-|\Z)',
    re.DOTALL
)
for m in pattern.finditer(content):
    req_id  = m.group(1)
    title   = m.group(3).strip()
    body    = m.group(4)

    intent_m   = re.search(r'\*\*Intent:\*\*\s*(.+)', body)
    accept_m   = re.search(r'\*\*Acceptance:\*\*\s*(.+)', body)
    priority_m = re.search(r'\*\*Priority:\*\*\s*(.+)', body)
    probe_m    = re.search(r'\*\*Probe hint:\*\*\s*(.+)', body)

    reqs.append({
        'id':         req_id,
        'key':        req_id.lower().replace('-', '_'),
        'title':      title,
        'intent':     intent_m.group(1).strip()    if intent_m   else '',
        'acceptance': accept_m.group(1).strip()    if accept_m   else '',
        'priority':   priority_m.group(1).strip()  if priority_m else 'must',
        'probe':      probe_m.group(1).strip()      if probe_m    else '',
    })

print(json.dumps(reqs))
PYEOF
}

_validate_req_schema() {
  python3 - "$REQ_FILE" << 'PYEOF'
import sys, re

with open(sys.argv[1]) as f:
    content = f.read()

reqs = re.findall(r'##\s+(REQ-\d+:[^\n]+)', content)
if not reqs:
    print("No REQ-NNN sections found", file=sys.stderr); sys.exit(1)

errors = []
for req in reqs:
    req_id = req.split(':')[0].strip()
    section_m = re.search(
        rf'##\s+{re.escape(req_id)}.*?(?=\n##\s+REQ-|\Z)', content, re.DOTALL
    )
    if not section_m:
        continue
    section = section_m.group()
    if '**Intent:**'     not in section: errors.append(f"{req_id}: missing **Intent:**")
    if '**Acceptance:**' not in section: errors.append(f"{req_id}: missing **Acceptance:**")
    if '**Priority:**'   not in section: errors.append(f"{req_id}: missing **Priority:**")

if errors:
    for e in errors: print(f"  {e}", file=sys.stderr)
    sys.exit(1)
print(len(reqs))
PYEOF
}

# ── Phase 0: Preflight ────────────────────────────────────────────────────────
hdr "Phase 0 — Preflight"
echo ""

if [ ! -f "$REQ_FILE" ]; then
  err "REQUIREMENTS.md not found in $PROJECT_PATH"
  echo "" >&2
  echo "  Run req-init.sh first:" >&2
  echo "    $_HEPH_DIR/req-init.sh $PROJECT_PATH" >&2
  exit 1
fi
ok "REQUIREMENTS.md found"

REQ_COUNT=$(_validate_req_schema) || {
  err "REQUIREMENTS.md schema invalid — fix the errors above, then re-run goal-init.sh"
  exit 1
}
ok "Schema valid — ${REQ_COUNT} REQ(s) found"

REQS_JSON=$(_parse_reqs)
echo ""
python3 -c "
import json, sys
reqs = json.loads(sys.argv[1])
print(f'  {\"ID\":<10} {\"Priority\":<12} Title')
print(f'  {\"─\"*10} {\"─\"*12} {\"─\"*40}')
for r in reqs:
    print(f'  {r[\"id\"]:<10} {r[\"priority\"]:<12} {r[\"title\"]}')
" "$REQS_JSON"

# ── Phase 1: Gap Analysis ─────────────────────────────────────────────────────
hdr "Phase 1 — Gap Analysis ($(basename "$PROJECT_PATH"))"
echo ""
echo "  Packing codebase with repomix..."

REPOMIX_FILE="/tmp/repomix-$(basename "$PROJECT_PATH")-$$.xml"
repomix --compress -o "$REPOMIX_FILE" "$PROJECT_PATH" 2>/dev/null
ok "Codebase packed → $REPOMIX_FILE"
REPOMIX_CONTENT=$(cat "$REPOMIX_FILE")

echo "  Calling ${GEN_MODEL} for gap analysis..."

GAP_PROMPT="You are analyzing a software project against its requirements.

For each requirement below, determine the current implementation status:
- \"passing\" — the code already satisfies this requirement
- \"failing\"  — the code clearly does not satisfy this requirement
- \"unknown\"  — cannot determine from the source alone

Requirements:
$(python3 -c "
import json, sys
reqs = json.loads(sys.argv[1])
for r in reqs:
    print(f\"  {r['id']}: {r['title']}\")
    print(f\"    Acceptance: {r['acceptance']}\")
" "$REQS_JSON")

Project source (repomix compressed):
${REPOMIX_CONTENT}

IMPORTANT: Respond with ONLY a JSON object. No prose. No markdown fences.
Schema:
{
  \"REQ-001\": \"passing\",
  \"REQ-002\": \"failing\",
  ...
}"

GAP_JSON=""
for attempt in 1 2 3; do
  _err=$(mktemp)
  GAP_RAW=$(ai_run_prompt "$GAP_PROMPT" 2>"$_err") || {
    echo "  Attempt $attempt: API error — $(cat "$_err") — retrying..." >&2
    rm -f "$_err"; continue
  }
  rm -f "$_err"
  GAP_JSON=$(echo "$GAP_RAW" | _extract_json) && break
  echo "  Attempt $attempt: could not parse JSON — retrying..." >&2
  GAP_JSON=""
done

[ -n "${GAP_JSON:-}" ] || {
  err "Gap analysis failed after 3 attempts — defaulting all to unknown"
  GAP_JSON=$(python3 -c "
import json, sys
reqs = json.loads(sys.argv[1])
print(json.dumps({r['id']: 'unknown' for r in reqs}))
" "$REQS_JSON")
}

echo ""
python3 -c "
import json, sys
reqs = json.loads(sys.argv[1])
gap  = json.loads(sys.argv[2])
print(f'  {\"REQ\":<10} {\"Status\":<10} Title')
print(f'  {\"─\"*10} {\"─\"*10} {\"─\"*40}')
for r in reqs:
    status = gap.get(r['id'], 'unknown')
    icon = {'passing': '✓', 'failing': '✗', 'unknown': '?'}.get(status, '?')
    print(f'  {r[\"id\"]:<10} {icon} {status:<8} {r[\"title\"]}')
" "$REQS_JSON" "$GAP_JSON"

echo ""
REFINEMENTS=0
while true; do
  ask "Does this gap analysis look right? [y/n]" GAP_REVIEW
  case "${GAP_REVIEW,,}" in
    y|yes) break ;;
    n|no)
      if [ "$REFINEMENTS" -ge 3 ]; then
        err "Max refinements (3) reached."
        break
      fi
      ask "What is wrong? (e.g. 'REQ-002 is actually passing')" GAP_CORRECTION
      GAP_JSON=$(python3 -c "
import json, sys, re
gap = json.loads(sys.argv[1])
correction = sys.argv[2].lower()
for req_id in list(gap.keys()):
    if req_id.lower() in correction:
        for status in ['passing', 'failing', 'unknown']:
            if status in correction:
                gap[req_id] = status
                break
print(json.dumps(gap))
" "$GAP_JSON" "$GAP_CORRECTION")
      echo ""
      python3 -c "
import json, sys
reqs = json.loads(sys.argv[1])
gap  = json.loads(sys.argv[2])
for r in reqs:
    status = gap.get(r['id'], 'unknown')
    icon = {'passing': '✓', 'failing': '✗', 'unknown': '?'}.get(status, '?')
    print(f'  {r[\"id\"]}: {icon} {status} — {r[\"title\"]}')
" "$REQS_JSON" "$GAP_JSON"
      REFINEMENTS=$((REFINEMENTS + 1))
      ;;
    *) echo "  Please enter: y or n" ;;
  esac
done

# ── Phase 2: Generate score.sh ────────────────────────────────────────────────
hdr "Phase 2 — Generating score.sh"
echo ""

SCORE_PROMPT="You are generating a score.sh for a hephaestus Worker↔Reviewer loop.

Requirements (source of truth):
$(cat "$REQ_FILE")

Gap analysis (current status):
$(python3 -c "
import json, sys
reqs = json.loads(sys.argv[1])
gap  = json.loads(sys.argv[2])
for r in reqs:
    status = gap.get(r['id'], 'unknown')
    print(f\"  {r['id']} ({status}): {r['acceptance']}\")
    if r['probe']:
        print(f\"    Probe hint: {r['probe']}\")
" "$REQS_JSON" "$GAP_JSON")

Project directory: ${PROJECT_PATH}

Instructions:
1. Write score.sh into ${PROJECT_PATH}/score.sh
2. Line 1: #!/usr/bin/env bash
3. Line 2: # generated-by: goal-init.sh
4. One bash function per REQ, keyed exactly as: req_001, req_002, etc.
5. Each function implements the Acceptance criterion as a behavioral probe
6. Use the Probe hint if provided; derive a probe from Acceptance if not
7. REQs with status 'passing' start at their full point value (regression detection)
8. REQs with status 'failing' or 'unknown' start at 0 (improvement target)
9. Point distribution: divide 100 evenly across all REQs
10. --json flag must return: {\"score\": N, \"req_001\": N, \"req_002\": N, ...}
    All values must be integers 0..100. No strings, no floats.
11. Plain mode (no flag): print one integer to stdout
12. Breakdown to stderr in both modes
13. Do NOT include linter/coverage checks unless a REQ explicitly requires them
14. Write the file directly. Do not explain."

echo "  How should score.sh be written?"
echo ""
if command -v codex &>/dev/null; then
  echo "  1) codex       — agentic, explores project, writes files directly"
else
  echo "  1) codex       — (not on PATH, unavailable)"
fi
if command -v claude &>/dev/null; then
  echo "  2) claude-code — agentic, tool use"
else
  echo "  2) claude-code — (not on PATH, unavailable)"
fi
echo "  3) REST API    — fallback, shell-parses LLM output"
echo ""
ask "Choice [1-3]" ENGINE_CHOICE

case "${ENGINE_CHOICE:-3}" in
  1)
    if ! command -v codex &>/dev/null; then
      err "codex not on PATH — falling back to REST API"; ENGINE_CHOICE=3
    else
      echo "  Running codex in ${PROJECT_PATH} ..."
      (cd "$PROJECT_PATH" && codex exec --full-auto "$SCORE_PROMPT") || true
    fi
    ;;
  2)
    if ! command -v claude &>/dev/null; then
      err "claude not on PATH — falling back to REST API"; ENGINE_CHOICE=3
    else
      echo "  Running claude-code in ${PROJECT_PATH} ..."
      (cd "$PROJECT_PATH" && claude --dangerously-skip-permissions "$SCORE_PROMPT") || true
    fi
    ;;
esac

if [ "${ENGINE_CHOICE:-3}" = "3" ]; then
  echo "  Calling REST API for score.sh ..."
  SCORE_FILE_PROMPT="${SCORE_PROMPT}

Write score.sh content only. Start your output with: #!/usr/bin/env bash
Your second line must be exactly: # generated-by: goal-init.sh
Output the script content only — no preamble, no explanation."

  SCORE_CONTENT=$(ai_run_prompt "$SCORE_FILE_PROMPT" 2>/dev/null) || {
    err "REST API failed for score.sh — check OR_KEY and GEN_MODEL"
    exit 1
  }
  printf '%s\n' "$SCORE_CONTENT" > "$PROJECT_PATH/score.sh"
  chmod +x "$PROJECT_PATH/score.sh"
  ok "score.sh written"
fi

# ── Phase 3: Generate GOAL.md ─────────────────────────────────────────────────
hdr "Phase 3 — Generating GOAL.md"
echo ""

echo "  Failing REQs (action targets):"
python3 -c "
import json, sys
reqs = json.loads(sys.argv[1])
gap  = json.loads(sys.argv[2])
failing = [r for r in reqs if gap.get(r['id'], 'unknown') in ('failing', 'unknown')]
if failing:
    for r in failing:
        print(f\"    {r['id']}: {r['title']}\")
        print(f\"      Acceptance: {r['acceptance']}\")
else:
    print('    (none — all passing!)')
" "$REQS_JSON" "$GAP_JSON"
echo ""
echo "  Passing REQs (must not regress):"
python3 -c "
import json, sys
reqs = json.loads(sys.argv[1])
gap  = json.loads(sys.argv[2])
passing = [r for r in reqs if gap.get(r['id'], 'unknown') == 'passing']
if passing:
    for r in passing:
        print(f\"    {r['id']}: {r['title']}\")
else:
    print('    (none)')
" "$REQS_JSON" "$GAP_JSON"

GOAL_PROMPT="You are initializing a hephaestus Worker↔Reviewer loop.

Requirements (source of truth):
$(cat "$REQ_FILE")

Gap analysis:
$(python3 -c "
import json, sys
reqs = json.loads(sys.argv[1])
gap  = json.loads(sys.argv[2])
for r in reqs:
    status = gap.get(r['id'], 'unknown')
    print(f\"  {r['id']} ({status}): {r['title']}\")
" "$REQS_JSON" "$GAP_JSON")

Project directory: ${PROJECT_PATH}

Instructions:
1. Write GOAL.md into ${PROJECT_PATH}/GOAL.md with this structure:
   - First line: # Goal: <descriptive title>
   - ## Fitness Function: list each REQ with its point value and probe key
   - ## Stopping Condition: all REQs passing for 3 consecutive runs
   - ## Action Catalog: one entry per FAILING REQ only
     Each entry: file/line target, concrete fix, validation command
   - ## Do Not Touch: list PASSING REQs — these must not regress
   - Last line (exactly): <!-- generated-by: goal-init.sh -->
2. Action Catalog entries must be concrete and actionable — name files, functions if visible
3. Do NOT add generic advice — every action must target a specific failing Acceptance criterion
4. Write the file directly. Do not explain."

echo ""
echo "  Generating GOAL.md ..."

case "${ENGINE_CHOICE:-3}" in
  1)
    (cd "$PROJECT_PATH" && codex exec --full-auto "$GOAL_PROMPT") || true
    ;;
  2)
    (cd "$PROJECT_PATH" && claude --dangerously-skip-permissions "$GOAL_PROMPT") || true
    ;;
  3)
    GOAL_FILE_PROMPT="${GOAL_PROMPT}

Write GOAL.md content only. Start your output with: # Goal:
Your last line must be exactly: <!-- generated-by: goal-init.sh -->
Output the file content only — no preamble, no explanation."

    GOAL_CONTENT=$(ai_run_prompt "$GOAL_FILE_PROMPT" 2>/dev/null) || {
      err "REST API failed for GOAL.md — check OR_KEY and GEN_MODEL"
      exit 1
    }
    printf '%s\n' "$GOAL_CONTENT" > "$PROJECT_PATH/GOAL.md"
    ok "GOAL.md written"
    ;;
esac

# ── Verification ──────────────────────────────────────────────────────────────
hdr "Verification"
echo ""

[ -f "$PROJECT_PATH/GOAL.md"  ] || { err "GOAL.md not written"; exit 1; }
[ -f "$PROJECT_PATH/score.sh" ] || { err "score.sh not written"; exit 1; }
chmod +x "$PROJECT_PATH/score.sh"

grep -q 'generated-by: goal-init.sh' "$PROJECT_PATH/GOAL.md" || {
  err "GOAL.md missing provenance marker — last line must be: <!-- generated-by: goal-init.sh -->"
  exit 1
}
grep -q 'generated-by: goal-init.sh' "$PROJECT_PATH/score.sh" || {
  err "score.sh missing provenance marker — line 2 must be: # generated-by: goal-init.sh"
  exit 1
}
ok "Provenance markers present"

PLAIN=$(bash "$PROJECT_PATH/score.sh" 2>/dev/null) || {
  err "score.sh exited non-zero in plain mode"
  exit 1
}
echo "$PLAIN" | grep -qE '^[0-9]+$' || {
  err "score.sh plain mode: expected integer, got: ${PLAIN}"
  exit 1
}
ok "Plain mode: ${PLAIN}"

JSON_OUT=$(bash "$PROJECT_PATH/score.sh" --json 2>/dev/null) || {
  err "score.sh exited non-zero in --json mode"
  exit 1
}
if ! python3 - "$REQS_JSON" "$JSON_OUT" << 'PYEOF'
import sys, json

reqs = json.loads(sys.argv[1])
out  = json.loads(sys.argv[2])

assert 'score' in out, 'missing score key'

for k, v in out.items():
    assert isinstance(v, int), \
        f'{k}: expected int, got {type(v).__name__} ({v!r})'
    assert 0 <= v <= 100, \
        f'{k}: value {v} out of range 0..100'

expected_keys = {r['key'] for r in reqs}
actual_keys   = {k for k in out.keys() if k != 'score'}
missing       = expected_keys - actual_keys
assert not missing, 'missing REQ keys in --json output: ' + str(sorted(missing))
PYEOF
then
  err "score.sh --json: failed REQ key / numeric validation (see above)"
  exit 1
fi
ok "--json mode: all REQ keys present, all values int 0..100"

echo ""
ok "GOAL.md and score.sh written and verified."
echo ""
echo "  Next step: run setup.sh to configure the loop."
