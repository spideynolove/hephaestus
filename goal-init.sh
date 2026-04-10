#!/usr/bin/env bash
# goal-init.sh — Two-phase project-specific GOAL.md + score.sh generator
#
# Usage: goal-init.sh <project-path>
#
# Phase 1: repomix packs project → REST API analyzes → user approves brief
# Phase 2: agentic engine writes GOAL.md + score.sh from approved brief
set -euo pipefail

# shellcheck source=/dev/null
if [ -f ~/.secrets ]; then source ~/.secrets 2>/dev/null || true; fi

hr()  { echo ""; echo "────────────────────────────────────────────────"; }
hdr() { hr; echo " $*"; hr; }
ok()  { echo "  ✓ $*"; }
err() { echo "  ✗ $*" >&2; }
ask() {
  printf "  %s: " "$1"; read -r "$2"
  if [ -t 0 ]; then
    while read -r -t 0.2 _drain; do :; done
    sleep 0.1
    while read -r -t 0.2 _drain; do :; done
  fi
}

PROJECT_PATH="${1:-}"
[ -z "$PROJECT_PATH" ] && { err "Usage: goal-init.sh <project-path>"; exit 1; }
[ -d "$PROJECT_PATH" ] || { err "Not a directory: $PROJECT_PATH"; exit 1; }
PROJECT_PATH="$(cd "$PROJECT_PATH" && pwd)"
BRIEF_FILE="$PROJECT_PATH/.goal-brief.json"

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

_print_brief() {
  python3 -c "
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
" "$1"
}

_build_phase1_prompt() {
  local repomix_content="$1"
  local correction="${2:-}"
  local correction_section=""
  if [ -n "$correction" ]; then
    correction_section="
The user says the previous analysis was wrong: ${correction}
Revise your analysis accordingly.
"
  fi
  cat << PROMPT_EOF
You are analyzing a software project to build a precise fitness function for
an autonomous improvement loop. Do not guess — derive everything from the
source below.

IMPORTANT: Respond with ONLY a single JSON object. No prose before it.
No prose after it. No markdown fences. No explanation. Raw JSON only.

Required schema:
{
  "purpose": "one sentence — what this project does for its users",
  "capabilities": ["3-5 specific behaviors that must always work"],
  "broken_signals": ["what a user notices first when broken"],
  "gaps": ["weaknesses or missing features visible in the source"]
}
${correction_section}
Project source (repomix compressed):
${repomix_content}
PROMPT_EOF
}

_run_phase1() {
  local repomix_content="$1"
  local correction="${2:-}"
  local prompt raw brief
  prompt=$(_build_phase1_prompt "$repomix_content" "$correction")
  for attempt in 1 2 3; do
    raw=$(ai_run_prompt "$prompt" 2>/dev/null) || {
      echo "  Attempt $attempt: API error — retrying..." >&2
      continue
    }
    brief=$(echo "$raw" | _extract_json) && { echo "$brief"; return 0; }
    echo "  Attempt $attempt: could not parse JSON — retrying..." >&2
  done
  return 1
}

# ── Phase 1: Analyze ─────────────────────────────────────────────────────────
hdr "Phase 1 — Analyzing $(basename "$PROJECT_PATH")"
echo ""
echo "  Packing codebase with repomix..."

REPOMIX_FILE="/tmp/repomix-$(basename "$PROJECT_PATH")-$$.xml"
repomix --compress -o "$REPOMIX_FILE" "$PROJECT_PATH" 2>/dev/null
ok "Codebase packed → $REPOMIX_FILE"
REPOMIX_CONTENT=$(cat "$REPOMIX_FILE")

echo "  Calling ${GEN_MODEL:-model} for First Principles analysis..."
BRIEF_JSON=$(_run_phase1 "$REPOMIX_CONTENT") || {
  err "Phase 1 failed after 3 attempts. Check OR_KEY and GEN_MODEL."
  exit 1
}
echo ""
_print_brief "$BRIEF_JSON"

# ── Review loop ───────────────────────────────────────────────────────────────
REFINEMENTS=0
CORRECTION=""
while true; do
  echo ""
  ask "Does this look right? [y / n / edit]" REVIEW_CHOICE
  case "${REVIEW_CHOICE,,}" in
    y|yes)
      break
      ;;
    n|no)
      if [ "$REFINEMENTS" -ge 3 ]; then
        err "Max refinements (3) reached. Edit manually or restart."
        exit 1
      fi
      ask "What's wrong with this analysis?" CORRECTION
      echo "  Re-analyzing..."
      BRIEF_JSON=$(_run_phase1 "$REPOMIX_CONTENT" "$CORRECTION") || {
        err "Phase 1 failed after 3 attempts."
        exit 1
      }
      echo ""
      _print_brief "$BRIEF_JSON"
      REFINEMENTS=$((REFINEMENTS + 1))
      ;;
    e|edit)
      echo "$BRIEF_JSON" > "$BRIEF_FILE"
      ${EDITOR:-vi} "$BRIEF_FILE"
      BRIEF_JSON=$(cat "$BRIEF_FILE")
      if ! python3 -c "import json,sys; json.loads(sys.argv[1])" "$BRIEF_JSON" 2>/dev/null; then
        err "Invalid JSON after edit — try again"
        continue
      fi
      echo ""
      _print_brief "$BRIEF_JSON"
      ;;
    *)
      echo "  Please enter: y, n, or edit"
      ;;
  esac
done

echo "$BRIEF_JSON" > "$BRIEF_FILE"
ok "Brief approved and saved to $BRIEF_FILE"

# ── Phase 2: Write files ──────────────────────────────────────────────────────
hdr "Phase 2 — Writing GOAL.md + score.sh"
echo ""

_brief_list() {
  python3 -c "
import json, sys
b = json.load(open(sys.argv[1]))
field = sys.argv[2]
val = b.get(field, [])
if isinstance(val, list):
    for i, v in enumerate(val, 1):
        print(f'    {i}. {v}')
else:
    print('    ' + str(val))
" "$BRIEF_FILE" "$1"
}

_brief_scalar() {
  python3 -c "
import json, sys
b = json.load(open(sys.argv[1]))
print(b.get(sys.argv[2], ''))
" "$BRIEF_FILE" "$1"
}

PURPOSE=$(_brief_scalar purpose)
CAP_KEYS=$(python3 -c "
import json, sys
b = json.load(open(sys.argv[1]))
normalize = lambda c: c.lower().strip().replace(' ', '_')[:20]
print(', '.join(normalize(c) for c in b.get('capabilities', [])))
" "$BRIEF_FILE")

SEEDED_PROMPT="You are initializing a hephaestus Worker↔Reviewer loop.

Project brief — validated by the user. Treat as ground truth:
  Purpose: ${PURPOSE}

  Core capabilities (MUST appear in score.sh as individually scored sections):
$(_brief_list capabilities)

  Broken signals:
$(_brief_list broken_signals)

  Current gaps (MUST appear in Action Catalog):
$(_brief_list gaps)

Instructions:
1. Use the sequential-thinking skill: reason from First Principles about what
   \"excellent\" looks like for THIS specific project before writing anything.
2. Write GOAL.md into ${PROJECT_PATH}/GOAL.md:
   - First line: # Goal: <descriptive title>
   - Fitness function: one scored section per capability, totalling 100 pts
   - Stopping condition: score >= 90 for 3 consecutive runs
   - Improvement loop (numbered steps)
   - Action catalog targeting the gaps listed above
   - Constraints from the project's actual requirements
   - Last line (exactly): <!-- generated-by: goal-init.sh -->
3. Write score.sh into ${PROJECT_PATH}/score.sh:
   - Line 1: #!/usr/bin/env bash
   - Line 2: # generated-by: goal-init.sh
   - One scored section per capability — run a REAL behavioral probe per section
   - Capability key normalization (use exactly this rule):
       key = capability.lower().strip().replace(' ', '_')[:20]
     Expected keys: ${CAP_KEYS}
   - --json flag must return: {\"score\":N, \"<cap_key>\":N, ...} for every
     expected key listed above — every value must be an integer 0..100,
     no strings, no floats
   - Plain mode (no flag): print one integer to stdout
   - Breakdown to stderr in both modes
   - Do NOT write generic lint/coverage unless that IS a listed capability
4. Write both files. Do not explain."

# ── Engine selection ──────────────────────────────────────────────────────────
echo "  How should GOAL.md + score.sh be written?"
echo ""
if command -v codex &>/dev/null; then
  echo "  1) codex       — agentic, explores project, writes files directly"
else
  echo "  1) codex       — (not on PATH, unavailable)"
fi
if command -v claude &>/dev/null; then
  echo "  2) claude-code — agentic, tool use, sequential-thinking skill available"
else
  echo "  2) claude-code — (not on PATH, unavailable)"
fi
echo "  3) REST API    — fallback, shell-parses LLM output"
echo ""
ask "Choice [1-3]" ENGINE_CHOICE

case "${ENGINE_CHOICE:-3}" in
  1)
    if ! command -v codex &>/dev/null; then
      err "codex not on PATH — falling back to REST API"
      ENGINE_CHOICE=3
    else
      echo "  Running codex in ${PROJECT_PATH} ..."
      (cd "$PROJECT_PATH" && codex exec --full-auto "$SEEDED_PROMPT") || true
    fi
    ;;
  2)
    if ! command -v claude &>/dev/null; then
      err "claude not on PATH — falling back to REST API"
      ENGINE_CHOICE=3
    else
      echo "  Running claude-code in ${PROJECT_PATH} ..."
      (cd "$PROJECT_PATH" && claude --dangerously-skip-permissions "$SEEDED_PROMPT") || true
    fi
    ;;
esac

if [ "${ENGINE_CHOICE:-3}" = "3" ]; then
  echo "  Calling REST API (two calls: GOAL.md then score.sh) ..."

  GOAL_PROMPT="${SEEDED_PROMPT}

Write GOAL.md content only. Start your output with: # Goal:
Your last line must be exactly: <!-- generated-by: goal-init.sh -->
Output the file content only — no preamble, no explanation."

  SCORE_PROMPT="${SEEDED_PROMPT}

Write score.sh content only. Start your output with: #!/usr/bin/env bash
Your second line must be exactly: # generated-by: goal-init.sh
Output the script content only — no preamble, no explanation."

  echo "  Generating GOAL.md ..."
  GOAL_CONTENT=$(ai_run_prompt "$GOAL_PROMPT" 2>/dev/null) || {
    err "REST API failed for GOAL.md — check OR_KEY and GEN_MODEL"
    exit 1
  }
  printf '%s\n' "$GOAL_CONTENT" > "$PROJECT_PATH/GOAL.md"
  ok "GOAL.md written"

  echo "  Generating score.sh ..."
  SCORE_CONTENT=$(ai_run_prompt "$SCORE_PROMPT" 2>/dev/null) || {
    err "REST API failed for score.sh — check OR_KEY and GEN_MODEL"
    exit 1
  }
  printf '%s\n' "$SCORE_CONTENT" > "$PROJECT_PATH/score.sh"
  chmod +x "$PROJECT_PATH/score.sh"
  ok "score.sh written"
fi

# ── Verification ─────────────────────────────────────────────────────────────
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
if ! python3 - "$BRIEF_FILE" "$JSON_OUT" <<'PYEOF'
import sys, json

with open(sys.argv[1]) as f:
    brief = json.load(f)

out = json.loads(sys.argv[2])
assert 'score' in out, 'missing score key'

for k, v in out.items():
    assert isinstance(v, int), \
        f'{k}: expected int, got {type(v).__name__} ({v!r})'
    assert 0 <= v <= 100, \
        f'{k}: value {v} out of range 0..100'

normalize     = lambda c: c.lower().strip().replace(' ', '_')[:20]
expected_keys = {normalize(c) for c in brief.get('capabilities', [])}
actual_keys   = {normalize(k) for k in out.keys() if k != 'score'}
missing       = expected_keys - actual_keys
assert not missing, 'missing capability keys: ' + str(sorted(missing))
PYEOF
then
  err "score.sh --json: failed numeric/capability validation (see above)"
  exit 1
fi
ok "--json mode: all capability keys present, all values int 0..100"

echo ""
ok "GOAL.md and score.sh written and verified."
echo ""
echo "  Next step: run setup.sh to configure the loop."
