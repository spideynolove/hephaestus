#!/usr/bin/env bash
# req-init.sh — Convert a raw idea into a validated REQUIREMENTS.md
#
# Usage:
#   req-init.sh <project-path> [--idea "raw text"]
#   req-init.sh <project-path> [--idea-file path]
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
export OR_KEY
GEN_MODEL="${GEN_MODEL:-${WORKER_MODEL:-minimax/minimax-m2.7}}"
export GEN_MODEL

hr()  { echo ""; echo "────────────────────────────────────────────────"; }
hdr() { hr; echo " $*"; hr; }
ok()  { echo "  ✓ $*"; }
err() { echo "  ✗ $*" >&2; }
ask() { printf "  %s: " "$1"; read -r "$2"; }

PROJECT_PATH="${1:-}"
[ -z "$PROJECT_PATH" ] && { err "Usage: req-init.sh <project-path> [--idea \"text\" | --idea-file path]"; exit 1; }
[ -d "$PROJECT_PATH" ] || { err "Not a directory: $PROJECT_PATH"; exit 1; }
PROJECT_PATH="$(cd "$PROJECT_PATH" && pwd)"
PROJECT_NAME="$(basename "$PROJECT_PATH")"
REQ_FILE="$PROJECT_PATH/REQUIREMENTS.md"
SYS_PROMPT_FILE="$_HEPH_DIR/req-system-prompt.md"

shift
IDEA=""
IDEA_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --idea)      IDEA="$2"; shift 2 ;;
    --idea-file) IDEA_FILE="$2"; shift 2 ;;
    *) err "Unknown argument: $1"; exit 1 ;;
  esac
done

[ -f "$SYS_PROMPT_FILE" ] || { err "req-system-prompt.md not found at: $SYS_PROMPT_FILE"; exit 1; }
SYS_PROMPT="$(cat "$SYS_PROMPT_FILE")"

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

_validate_requirements() {
  local file="$1"
  python3 - "$file" << 'PYEOF'
import sys, re

with open(sys.argv[1]) as f:
    content = f.read()

reqs = re.findall(r'##\s+(REQ-\d+:[^\n]+)', content)
if not reqs:
    print("ERROR: No REQ-NNN sections found", file=sys.stderr)
    sys.exit(1)

errors = []
for req in reqs:
    req_id = req.split(':')[0].strip()
    section_match = re.search(
        rf'##\s+{re.escape(req_id)}.*?(?=\n##\s+REQ-|\Z)',
        content, re.DOTALL
    )
    if not section_match:
        continue
    section = section_match.group()
    if '**Intent:**' not in section:
        errors.append(f"{req_id}: missing **Intent:**")
    if '**Acceptance:**' not in section:
        errors.append(f"{req_id}: missing **Acceptance:**")
    if '**Priority:**' not in section:
        errors.append(f"{req_id}: missing **Priority:**")

if errors:
    for e in errors:
        print(f"  ✗ {e}", file=sys.stderr)
    sys.exit(1)

print(f"  ✓ {len(reqs)} REQ(s) validated")
PYEOF
}

hdr "req-init — Requirements for: $PROJECT_NAME"
echo ""

if [ -n "$IDEA_FILE" ]; then
  [ -f "$IDEA_FILE" ] || { err "Idea file not found: $IDEA_FILE"; exit 1; }
  IDEA="$(cat "$IDEA_FILE")"
fi

if [ -z "$IDEA" ]; then
  echo "  Describe what you want this project to do."
  echo "  (Be as rough or detailed as you like — the AI will ask follow-up questions.)"
  echo ""
  ask "Your idea" IDEA
fi

[ -n "$IDEA" ] || { err "No idea provided."; exit 1; }

hdr "Phase 1 — Purpose Extraction"
echo ""
echo "  Calling ${GEN_MODEL} ..."

PHASE1_PROMPT="${SYS_PROMPT}

---
RAW IDEA:
${IDEA}

---
TASK — Phase 1: Purpose Extraction

Extract the core purpose from the raw idea above.
Ask at most 2 clarifying questions about:
- What problem does this solve?
- What does failure look like for the user?

Then write a one-sentence purpose statement and confirm it with the user.

Format your response as:
PURPOSE: <one sentence>
QUESTIONS:
1. <question if needed>
2. <question if needed>"

PHASE1_OUT=$(ai_run_prompt "$PHASE1_PROMPT") || { err "Phase 1 API call failed."; exit 1; }
echo ""
echo "$PHASE1_OUT"
echo ""
ask "Confirm purpose or clarify" PURPOSE_CONFIRM

hdr "Phase 2 — Requirement Elicitation"
echo ""
echo "  Calling ${GEN_MODEL} ..."

PHASE2_PROMPT="${SYS_PROMPT}

---
RAW IDEA:
${IDEA}

USER CLARIFICATION ON PURPOSE:
${PURPOSE_CONFIRM}

---
TASK — Phase 2: Requirement Elicitation

Elicit 3-7 specific requirements, one at a time. For each requirement:
1. Name one capability the system must have
2. State the observable outcome (what a user sees/gets)
3. Confirm it is testable by a shell script
4. Assign priority: must | should | nice-to-have

Output the full REQUIREMENTS.md document following this schema exactly:

# Requirements: ${PROJECT_NAME}
<!-- req-version: 1 -->

## REQ-001: <short title>
**Intent:** <user outcome, not implementation detail>
**Acceptance:** <single observable, shell-testable condition. \"Running X produces Y.\">
**Priority:** must | should | nice-to-have
**Probe hint:** (optional) <concrete command + expected output>

## REQ-002: ...

Rules:
- Each REQ covers exactly one testable condition (no \"and\" in Acceptance)
- Intent describes user outcome, never implementation
- Acceptance must be verifiable by a shell script without human judgment
- Include at least 3 REQs"

PHASE2_OUT=$(ai_run_prompt "$PHASE2_PROMPT") || { err "Phase 2 API call failed."; exit 1; }
echo ""
echo "$PHASE2_OUT"
echo ""

hdr "Phase 3 — Completeness Check"
echo ""
echo "  Calling ${GEN_MODEL} for completeness review ..."

PHASE3_PROMPT="${SYS_PROMPT}

---
DRAFT REQUIREMENTS:
${PHASE2_OUT}

---
TASK — Phase 3: Completeness Check

Review the draft requirements above.
- List any important capabilities that seem missing
- Flag any Acceptance criteria that are not shell-testable
- Ask the user what is missing before finalizing

Format:
MISSING: <list any gaps, or \"none\">
NON-TESTABLE: <list any Acceptance criteria that need revision, or \"none\">
QUESTION: <one question about what might be missing>"

PHASE3_OUT=$(ai_run_prompt "$PHASE3_PROMPT") || { err "Phase 3 API call failed."; exit 1; }
echo ""
echo "$PHASE3_OUT"
echo ""
ask "Anything to add or change?" COMPLETENESS_FEEDBACK

if [ -n "$COMPLETENESS_FEEDBACK" ] && [ "$COMPLETENESS_FEEDBACK" != "no" ] && [ "$COMPLETENESS_FEEDBACK" != "n" ]; then
  echo ""
  echo "  Revising requirements with your feedback..."
  REVISE_PROMPT="${SYS_PROMPT}

---
DRAFT REQUIREMENTS:
${PHASE2_OUT}

USER FEEDBACK:
${COMPLETENESS_FEEDBACK}

---
TASK: Revise the REQUIREMENTS.md document incorporating the user feedback.
Output the complete revised REQUIREMENTS.md following the same schema.
Include the <!-- req-version: 1 --> marker."

  FINAL_OUT=$(ai_run_prompt "$REVISE_PROMPT") || { err "Revision API call failed."; exit 1; }
else
  FINAL_OUT="$PHASE2_OUT"
fi

REQUIREMENTS_CONTENT=$(echo "$FINAL_OUT" | python3 -c "
import sys, re
text = sys.stdin.read()
m = re.search(r'(# Requirements:.*)', text, re.DOTALL)
if m:
    print(m.group(1).strip())
else:
    print(text.strip())
")

hdr "Review & Save"
echo ""
echo "$REQUIREMENTS_CONTENT"
echo ""
echo "  File will be written to: $REQ_FILE"
ask "Save? [y/n/edit]" SAVE_CHOICE

case "${SAVE_CHOICE,,}" in
  y|yes)
    printf '%s\n' "$REQUIREMENTS_CONTENT" > "$REQ_FILE"
    ;;
  e|edit)
    printf '%s\n' "$REQUIREMENTS_CONTENT" > "$REQ_FILE"
    ${EDITOR:-vi} "$REQ_FILE"
    ;;
  *)
    echo "  Aborted — nothing written."
    exit 0
    ;;
esac

echo ""
echo "  Validating schema..."
_validate_requirements "$REQ_FILE" || {
  err "Schema validation failed — edit $REQ_FILE and re-run validation:"
  err "  python3 req-init.sh --validate $REQ_FILE"
  exit 1
}

echo ""
ok "REQUIREMENTS.md written and validated: $REQ_FILE"
echo ""
echo "  Next step: run goal-init.sh $PROJECT_PATH"
