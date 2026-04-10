#!/usr/bin/env bash
# setup.sh — Interactive setup wizard for hephaestus
#
# Architecture:
#   Engine  = the agentic CLI that edits code (codex, claude-code)
#   Fuel    = the LLM inference service (OpenRouter, Anthropic, custom API)
#
# Steps:
#   0. Project path
#   1. LLM provider + model selection (fuel)
#   2. API connection test
#   3. GOAL.md + score.sh generation
#   4. Execution engine (codex / claude-code)
#   5. Notifications (optional)
#   6. Write .env + config.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load saved keys (non-fatal — file may not exist)
# shellcheck source=/dev/null
if [ -f ~/.secrets ]; then source ~/.secrets 2>/dev/null || true; fi

# ── Helpers ───────────────────────────────────────────────────────────────────
hr()  { echo ""; echo "────────────────────────────────────────────────"; }
hdr() { hr; echo " $*"; hr; }
ok()  { echo "  ✓ $*"; }
err() { echo "  ✗ $*"; }
ask() {
  printf "  %s: " "$1"; read -r "$2"
  if [ -t 0 ]; then
    while read -r -t 0.2 _drain; do :; done
    sleep 0.1
    while read -r -t 0.2 _drain; do :; done
  fi
}
askp() {
  printf "  %s: " "$1"; read -rs "$2"; echo ""
  if [ -t 0 ]; then
    while read -r -t 0.2 _drain; do :; done
    sleep 0.1
    while read -r -t 0.2 _drain; do :; done
  fi
}

# Call the LLM API (OpenRouter or compatible) with a plain-text prompt.
# Requires env vars: OR_KEY, OR_BASE_URL, GEN_MODEL
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


# ── Banner ────────────────────────────────────────────────────────────────────
clear
echo ""
echo "  ██╗  ██╗███████╗██████╗ ██╗  ██╗ █████╗ ███████╗███████╗██╗   ██╗███████╗"
echo "  ██║  ██║██╔════╝██╔══██╗██║  ██║██╔══██╗██╔════╝██╔════╝██║   ██║██╔════╝"
echo "  ███████║█████╗  ██████╔╝███████║███████║█████╗  ███████╗██║   ██║███████╗"
echo "  ██╔══██║██╔══╝  ██╔═══╝ ██╔══██║██╔══██║██╔══╝  ╚════██║██║   ██║╚════██║"
echo "  ██║  ██║███████╗██║     ██║  ██║██║  ██║███████╗███████║╚██████╔╝███████║"
echo "  ╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚══════╝ ╚═════╝ ╚══════╝"
echo ""
echo "  Worker↔Reviewer Loop — Setup Wizard"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# STEP 0: Project path
# ══════════════════════════════════════════════════════════════════════════════
hdr "Step 0 of 5 — Project"
echo ""
echo "  The loop needs to know which project to improve."
echo ""

ask "Path to the project you want to improve [$(pwd)]" PROJECT_PATH
PROJECT_PATH="${PROJECT_PATH:-$(pwd)}"
PROJECT_PATH="$(realpath "$PROJECT_PATH")"

if [ ! -d "$PROJECT_PATH" ]; then
  echo "  Directory not found: $PROJECT_PATH"
  exit 1
fi
ok "Project: $PROJECT_PATH"

GOAL_ACTION="create"
_has_goal=false; _has_score=false
[ -f "$PROJECT_PATH/GOAL.md"  ] && _has_goal=true
[ -f "$PROJECT_PATH/score.sh" ] && _has_score=true

if $_has_goal && $_has_score; then
  _goal_ok=false; _score_ok=false
  grep -q 'generated-by: goal-init.sh' "$PROJECT_PATH/GOAL.md"  2>/dev/null && _goal_ok=true
  grep -q 'generated-by: goal-init.sh' "$PROJECT_PATH/score.sh" 2>/dev/null && _score_ok=true

  if $_goal_ok && $_score_ok; then
    _plain=$(bash "$PROJECT_PATH/score.sh" 2>/dev/null || true)
    _json=$(bash  "$PROJECT_PATH/score.sh" --json 2>/dev/null || true)
    _brief="$PROJECT_PATH/.goal-brief.json"
    if echo "$_plain" | grep -qE '^[0-9]+$' && \
       python3 - "$_brief" "$_json" 2>/dev/null <<'PYEOF'
import json, sys, os
brief_path, json_out = sys.argv[1], sys.argv[2]
out = json.loads(json_out)
assert isinstance(out.get('score'), int), 'score not int'
assert os.path.exists(brief_path), 'brief not found — run goal-init.sh again'
with open(brief_path) as f:
    brief = json.load(f)
normalize = lambda c: c.lower().strip().replace(' ', '_')[:20]
expected = {normalize(c) for c in brief.get('capabilities', [])}
actual   = {normalize(k) for k in out.keys() if k != 'score'}
missing  = expected - actual
assert not missing, 'missing keys: ' + str(sorted(missing))
PYEOF
    then
      ok "GOAL.md + score.sh verified (provenance + smoke test) — skipping generation"
      GOAL_ACTION="keep"
    else
      echo "  GOAL.md + score.sh have goal-init.sh provenance but score.sh is broken."
      echo "  1) Keep anyway  2) Regenerate"
      ask "Choice [1-2]" GOAL_ACTION_CHOICE
      [[ "$GOAL_ACTION_CHOICE" == "2" ]] && GOAL_ACTION="create" || GOAL_ACTION="keep"
    fi
  else
    echo "  GOAL.md and score.sh exist but were not created by goal-init.sh."
    echo "  1) Keep existing files"
    echo "  2) Exit — then run: goal-init.sh $PROJECT_PATH, then re-run setup.sh"
    ask "Choice [1-2]" GOAL_ACTION_CHOICE
    if [[ "$GOAL_ACTION_CHOICE" == "2" ]]; then
      echo "  Run goal-init.sh $PROJECT_PATH first, then re-run setup.sh."
      exit 0
    fi
    GOAL_ACTION="keep"
  fi
elif $_has_goal && ! $_has_score; then
  echo "  GOAL.md exists but score.sh is missing — partial state."
  echo "  Run: goal-init.sh $PROJECT_PATH   (regenerates both)"
  exit 0
elif ! $_has_goal && $_has_score; then
  echo "  score.sh exists but GOAL.md is missing — partial state."
  echo "  Run: goal-init.sh $PROJECT_PATH   (regenerates both)"
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1: LLM provider (fuel)
# ══════════════════════════════════════════════════════════════════════════════
hdr "Step 1 of 5 — LLM Provider (fuel)"
echo ""
echo "  The LLM service provides inference for both Worker and Reviewer."
echo "  The agentic CLI (codex / claude-code) is just the engine — configured next."
echo ""
echo "  1) OpenRouter  (one API key → any model, recommended)"
echo "  2) Anthropic direct  (ANTHROPIC_API_KEY)"
echo "  3) Custom OpenAI-compatible endpoint"
echo "  4) OAuth only  (claude-code subscription, no API key)"
echo ""
ask "Choice [1-4]" PROVIDER_CHOICE

OR_KEY=""
OR_BASE_URL="https://openrouter.ai/api/v1"
WORKER_MODEL=""
REVIEWER_MODEL=""
GEN_MODEL=""
ENV_LINES=()

case "$PROVIDER_CHOICE" in
  1)
    echo ""
    if [ -n "${OPENROUTER_API_KEY:-}" ]; then
      OR_KEY="$(printf '%s' "$OPENROUTER_API_KEY" | tr -d '[:space:]')"
      ok "Using OPENROUTER_API_KEY from ~/.secrets (${OR_KEY:0:12}...)"
    else
      echo "  OpenRouter API key — get one at https://openrouter.ai/keys"
      echo ""
      askp "API key (sk-or-v1-...)" OR_KEY
      OR_KEY="$(printf '%s' "$OR_KEY" | tr -d '[:space:]')"
      _SAVE_OR_KEY=true
    fi
    echo ""
    echo "  Worker model executes code changes. Reviewer model writes feedback."
    echo ""
    echo "  Examples:"
    echo "    qwen/qwen3-coder-480b:free   openai/gpt-5.3-codex"
    echo "    google/gemini-2.5-pro        deepseek/deepseek-r1"
    echo "    anthropic/claude-opus-4.6    minimax/minimax-m2.7"
    echo ""
    ask "Worker model  [qwen/qwen3-coder-480b:free]" WORKER_MODEL
    WORKER_MODEL="${WORKER_MODEL:-qwen/qwen3-coder-480b:free}"
    ask "Reviewer model [deepseek/deepseek-r1:free]" REVIEWER_MODEL
    REVIEWER_MODEL="${REVIEWER_MODEL:-deepseek/deepseek-r1:free}"
    GEN_MODEL="$WORKER_MODEL"
    OR_BASE_URL="https://openrouter.ai/api/v1"
    ENV_LINES+=(
      "OR_KEY=${OR_KEY}"
      "OR_BASE_URL=${OR_BASE_URL}"
      "ANTHROPIC_BASE_URL=https://openrouter.ai/api"
      "ANTHROPIC_AUTH_TOKEN=${OR_KEY}"
      "ANTHROPIC_API_KEY="
      "OPENAI_BASE_URL=${OR_BASE_URL}"
      "OPENAI_API_KEY=${OR_KEY}"
      "WORKER_MODEL=${WORKER_MODEL}"
      "REVIEWER_MODEL=${REVIEWER_MODEL}"
    )
    ;;
  2)
    echo ""
    askp "Anthropic API key (sk-ant-...)" ANT_KEY
    OR_KEY="$ANT_KEY"
    OR_BASE_URL="https://api.anthropic.com/v1"
    WORKER_MODEL="claude-sonnet-4-6"
    REVIEWER_MODEL="claude-opus-4-6"
    GEN_MODEL="$WORKER_MODEL"
    ENV_LINES+=(
      "OR_KEY=${OR_KEY}"
      "OR_BASE_URL=${OR_BASE_URL}"
      "ANTHROPIC_API_KEY=${ANT_KEY}"
      "WORKER_MODEL=${WORKER_MODEL}"
      "REVIEWER_MODEL=${REVIEWER_MODEL}"
    )
    ;;
  3)
    echo ""
    ask "Base URL (OpenAI-compatible, e.g. https://api.deepseek.com/v1)" OR_BASE_URL
    askp "API key" OR_KEY
    OR_KEY="$(printf '%s' "$OR_KEY" | tr -d '[:space:]')"
    echo ""
    ask "Worker model" WORKER_MODEL
    ask "Reviewer model" REVIEWER_MODEL
    GEN_MODEL="$WORKER_MODEL"
    ENV_LINES+=(
      "OR_KEY=${OR_KEY}"
      "OR_BASE_URL=${OR_BASE_URL}"
      "OPENAI_BASE_URL=${OR_BASE_URL}"
      "OPENAI_API_KEY=${OR_KEY}"
      "WORKER_MODEL=${WORKER_MODEL}"
      "REVIEWER_MODEL=${REVIEWER_MODEL}"
    )
    ;;
  4)
    echo ""
    echo "  OAuth mode: no API key needed. GOAL.md will use a template."
    OR_KEY=""
    WORKER_MODEL="claude-sonnet-4-6"
    REVIEWER_MODEL="claude-opus-4-6"
    ENV_LINES+=("WORKER_MODEL=${WORKER_MODEL}" "REVIEWER_MODEL=${REVIEWER_MODEL}")
    ;;
  *)
    echo "Invalid choice. Exiting."; exit 1 ;;
esac

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2: Test API connection
# ══════════════════════════════════════════════════════════════════════════════
hdr "Step 2 of 5 — Testing API connection"
echo ""

_do_api_test() {
  OR_KEY="$OR_KEY" OR_BASE_URL="$OR_BASE_URL" GEN_MODEL="$GEN_MODEL" \
  python3 -c "
import json, sys, urllib.request, os
key   = os.environ['OR_KEY']
base  = os.environ.get('OR_BASE_URL', 'https://openrouter.ai/api/v1')
model = os.environ.get('GEN_MODEL', '')
data  = json.dumps({'model': model, 'messages': [{'role': 'user', 'content': 'respond with exactly: ok'}], 'max_tokens': 5}).encode()
req   = urllib.request.Request(base + '/chat/completions', data=data,
          headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
try:
    r = json.loads(urllib.request.urlopen(req, timeout=45).read())
    content = r['choices'][0]['message']['content'].strip().lower()
    sys.exit(0 if 'ok' in content else 1)
except urllib.error.HTTPError as e:
    print('HTTP ' + str(e.code) + ': ' + e.read().decode()[:200], file=sys.stderr); sys.exit(1)
except Exception as e:
    print(str(e), file=sys.stderr); sys.exit(1)
"
}

API_OK=false
if [ -n "$OR_KEY" ]; then
  _api_retry=true
  while $_api_retry; do
    echo "  Testing ${GEN_MODEL} via ${OR_BASE_URL} ..."
    _api_err=$(_do_api_test 2>&1 >/dev/null) && _api_ok=true || _api_ok=false

    if $_api_ok; then
      ok "API connection successful"
      API_OK=true
      _api_retry=false
      # Offer to save a newly entered key to ~/.secrets
      if [ "${_SAVE_OR_KEY:-false}" = "true" ]; then
        echo ""
        ask "Save key to ~/.secrets for future runs? [Y/n]" _SAVE_CHOICE
        if [[ ! "${_SAVE_CHOICE}" =~ ^[Nn]$ ]]; then
          if grep -q 'OPENROUTER_API_KEY' ~/.secrets 2>/dev/null; then
            sed -i "s|^export OPENROUTER_API_KEY=.*|export OPENROUTER_API_KEY=${OR_KEY}|" ~/.secrets
          else
            echo "export OPENROUTER_API_KEY=${OR_KEY}" >> ~/.secrets
          fi
          ok "Saved to ~/.secrets"
        fi
      fi
    else
      err "API test failed: ${_api_err}"
      echo ""
      echo "  1) Re-enter the API key"
      echo "  2) Continue anyway"
      echo "  3) Abort"
      ask "Choice [1-3]" _RETRY_CHOICE
      case "${_RETRY_CHOICE}" in
        1)
          askp "API key" OR_KEY
          OR_KEY="$(printf '%s' "$OR_KEY" | tr -d '[:space:]')"
          _SAVE_OR_KEY=true
          ;;
        2) API_OK=true; _api_retry=false ;;
        *) echo "  Aborted."; exit 1 ;;
      esac
    fi
  done
else
  ok "OAuth mode — skipping API test"
  API_OK=true
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3: GOAL.md + score.sh generation
# ══════════════════════════════════════════════════════════════════════════════
hdr "Step 3 of 5 — Project Goal"
echo ""

if [ "$GOAL_ACTION" = "create" ]; then
  echo "  Paste your goal / analysis below, then type '---' on its own line when done."
  echo "  (Press Enter immediately to skip and let the AI analyze the project.)"
  echo ""
  printf "  Goal context ('---' to finish):\n"

  USER_CONTEXT=""
  _ctx_first=true
  while IFS= read -r _ctx_line || break; do
    if $_ctx_first && [[ -z "$_ctx_line" ]]; then break; fi
    _ctx_first=false
    [[ "$_ctx_line" == "---" ]] && break
    USER_CONTEXT="${USER_CONTEXT}${_ctx_line}"$'\n'
  done
  echo ""

  # ── Pick generation method ───────────────────────────────────────────────
  echo "  How should GOAL.md + score.sh be generated?"
  echo ""
  if [ -n "$OR_KEY" ] && $API_OK; then
    echo "  1) REST API    — fast chat call to ${GEN_MODEL} via /api/v1/chat/completions"
  else
    echo "  1) REST API    — (no API configured, unavailable)"
  fi
  command -v codex  &>/dev/null && echo "  2) codex       — agentic, explores your project and writes files directly" \
                                || echo "  2) codex       — (not on PATH, unavailable)"
  command -v claude &>/dev/null && echo "  3) claude-code — agentic, uses tool calls to write files directly" \
                                || echo "  3) claude-code — (not on PATH, unavailable)"
  echo "  4) Template    — questionnaire only, no AI"
  echo ""
  ask "Choice [1-4]" GEN_METHOD_CHOICE

  _ctx_section=""
  if [ -n "$USER_CONTEXT" ]; then
    _ctx_section="The user provided this goal/analysis — use it to drive the fitness function and action catalog:

${USER_CONTEXT}---
"
  fi

  AI_GENERATED=false

  case "${GEN_METHOD_CHOICE:-1}" in
    # ── Method 1: REST API (/api/v1/chat/completions) ─────────────────────
    1)
      if [ -z "$OR_KEY" ] || ! $API_OK; then
        err "No API configured — falling back to template"
      else
        echo ""
        echo "  Calling ${GEN_MODEL} via REST API ..."

        _proj_context="Directory listing:\n$(ls -la "$PROJECT_PATH" 2>/dev/null)\n\n"
        for _cfg in pyproject.toml setup.cfg setup.py package.json go.mod Cargo.toml Makefile requirements.txt; do
          [ -f "$PROJECT_PATH/$_cfg" ] && \
            _proj_context="${_proj_context}=== $_cfg ===\n$(head -60 "$PROJECT_PATH/$_cfg")\n\n"
        done
        _test_file=$(find "$PROJECT_PATH" -maxdepth 3 \
          \( -name "test_*.py" -o -name "*.test.ts" -o -name "*.spec.js" \) 2>/dev/null | head -1)
        [ -n "$_test_file" ] && \
          _proj_context="${_proj_context}=== sample test: $_test_file ===\n$(head -30 "$_test_file")\n\n"

        AI_PROMPT=$(cat << AIPROMPT_EOF
IMPORTANT: Plain-text generation task. Do NOT use any tools. Do NOT write files. Output raw text only.

You are generating configuration for a hephaestus Worker-Reviewer loop.

Project directory: ${PROJECT_PATH}

${_ctx_section}Project files collected from disk:
$(printf '%b' "$_proj_context")

Respond with ONLY the two sections below — no preamble, no explanation.

=== GOAL.md ===
A GOAL.md tailored to this project with:
- Fitness function grounded in what this project actually measures
- Concrete stopping conditions and target score (default 90)
- Improvement Loop (step-by-step)
- Action Catalog with specific actionable items for this project's actual gaps
- Constraints from the project's actual requirements

=== score.sh ===
A bash script that:
- Starts with #!/usr/bin/env bash
- Outputs a single integer 0-100 to stdout
- Accepts --json flag returning {"score":N,"tests":N,"lint":N,"coverage":N}
- Uses the ACTUAL commands for this project (detect from pyproject.toml / package.json / Makefile)
- Writes score breakdown to stderr
- Contains only real executable commands, never placeholder echo statements

Respond now starting with: === GOAL.md ===
AIPROMPT_EOF
)
        export OR_KEY OR_BASE_URL GEN_MODEL
        AI_OUTPUT=$(ai_run_prompt "$AI_PROMPT" 2>&1) || true

        GOAL_CONTENT=$(echo "$AI_OUTPUT" | awk '/^=== GOAL\.md ===$/{f=1;next} /^=== score\.sh ===$/{f=0} f')
        SCORE_CONTENT=$(echo "$AI_OUTPUT" | awk '/^=== score\.sh ===$/{f=1;next} /^===[^=]/{f=0} f')

        if [ -n "$GOAL_CONTENT" ]; then
          printf '%s\n' "$GOAL_CONTENT" > "$PROJECT_PATH/GOAL.md"
          ok "GOAL.md written"
          AI_GENERATED=true
        else
          err "Could not parse GOAL.md from output — falling back to template"
        fi
        if [ -n "$SCORE_CONTENT" ]; then
          printf '%s\n' "$SCORE_CONTENT" > "$PROJECT_PATH/score.sh"
          chmod +x "$PROJECT_PATH/score.sh"
          ok "score.sh written"
        else
          err "Could not parse score.sh — will use template"
        fi
      fi
      ;;

    # ── Method 2: codex (agentic, /api/v1 endpoint) ───────────────────────
    2)
      if ! command -v codex &>/dev/null; then
        err "codex not on PATH — falling back to template"
      else
        echo ""
        echo "  Running codex in ${PROJECT_PATH} ..."
        _codex_prompt="You are setting up a hephaestus Worker-Reviewer loop for this project.

${_ctx_section}Analyze this project directory (${PROJECT_PATH}) — read the source files, tests, config files, and build system.

Create two files in ${PROJECT_PATH}/:

1. GOAL.md — fitness function, stopping conditions (target score 90), improvement loop steps, action catalog tailored to this project's actual gaps, constraints.

2. score.sh — executable bash script (chmod +x) that:
   - Outputs a single integer 0-100 to stdout
   - Accepts --json flag returning {\"score\":N,\"tests\":N,\"lint\":N,\"coverage\":N}
   - Uses this project's actual test/lint/coverage commands (detect from project files)
   - Writes breakdown to stderr

Write both files directly. Do not explain."

        (cd "$PROJECT_PATH" && codex exec --full-auto "$_codex_prompt") || true
        if [ -f "$PROJECT_PATH/GOAL.md"  ]; then ok "GOAL.md written by codex";  AI_GENERATED=true
        else err "codex did not create GOAL.md — falling back to template"; fi
        if [ -f "$PROJECT_PATH/score.sh" ]; then chmod +x "$PROJECT_PATH/score.sh"; ok "score.sh written by codex"
        else err "codex did not create score.sh — will use template"; fi
      fi
      ;;

    # ── Method 3: claude-code (agentic, /api endpoint) ────────────────────
    3)
      if ! command -v claude &>/dev/null; then
        err "claude not on PATH — falling back to template"
      else
        echo ""
        echo "  Running claude-code in ${PROJECT_PATH} ..."
        _claude_prompt="You are setting up a hephaestus Worker-Reviewer loop for this project.

${_ctx_section}Analyze this project directory (${PROJECT_PATH}) — read the source files, tests, config files, and build system.

Create two files in ${PROJECT_PATH}/:

1. GOAL.md — fitness function, stopping conditions (target score 90), improvement loop steps, action catalog tailored to this project's actual gaps, constraints.

2. score.sh — executable bash script (chmod +x) that:
   - Outputs a single integer 0-100 to stdout
   - Accepts --json flag returning {\"score\":N,\"tests\":N,\"lint\":N,\"coverage\":N}
   - Uses this project's actual test/lint/coverage commands (detect from project files)
   - Writes breakdown to stderr

Write both files directly using your file-writing tools. Do not explain."

        (cd "$PROJECT_PATH" && claude --dangerously-skip-permissions "$_claude_prompt") || true
        if [ -f "$PROJECT_PATH/GOAL.md"  ]; then ok "GOAL.md written by claude-code";  AI_GENERATED=true
        else err "claude-code did not create GOAL.md — falling back to template"; fi
        if [ -f "$PROJECT_PATH/score.sh" ]; then chmod +x "$PROJECT_PATH/score.sh"; ok "score.sh written by claude-code"
        else err "claude-code did not create score.sh — will use template"; fi
      fi
      ;;
  esac

  # ── Template fallback ─────────────────────────────────────────────────────
  if ! $AI_GENERATED; then
    GOAL_OBJECTIVE=$(printf '%s' "$USER_CONTEXT" | head -1)
    GOAL_OBJECTIVE="${GOAL_OBJECTIVE:-improve this project}"
    echo ""
    echo "  Collecting tool info for score.sh template."
    echo ""
    echo "  Test runner?  1) pytest  2) jest/npm test  3) go test  4) none"
    ask "Choice [1-4]" TEST_RUNNER_CHOICE
    echo "  Linter?       1) ruff    2) eslint         3) golint   4) none"
    ask "Choice [1-4]" LINT_CHOICE
    echo "  Coverage?     1) pytest-cov  2) jest --coverage  3) none"
    ask "Choice [1-3]" COV_CHOICE

    case "$TEST_RUNNER_CHOICE" in
      1) TEST_CMD="python -m pytest --tb=no -q" ;;
      2) TEST_CMD="npm test --silent" ;;
      3) TEST_CMD="go test ./... -v" ;;
      *) TEST_CMD="" ;;
    esac
    case "$LINT_CHOICE" in
      1) LINT_CMD="ruff check ." ;;
      2) LINT_CMD="npx eslint . --format compact" ;;
      3) LINT_CMD="golint ./..." ;;
      *) LINT_CMD="" ;;
    esac
    case "$COV_CHOICE" in
      1) COV_CMD="python -m pytest --cov=. --cov-report=term-missing -q" ;;
      2) COV_CMD="npx jest --coverage --coverageReporters=text-summary" ;;
      *) COV_CMD="" ;;
    esac

    {
      echo "# Goal: ${GOAL_OBJECTIVE}"
      echo ""
      [ -n "$USER_CONTEXT" ] && { echo "## Context"; echo ""; printf '%s\n' "$USER_CONTEXT"; }
      cat << 'TMPL'
## Fitness Function

```bash
bash score.sh
bash score.sh --json
```

## Improvement Loop

```
repeat:
  1. bash score.sh --json > /tmp/before.json
  2. Find weakest component
  3. Pick action from Action Catalog
  4. Make the change
  5. bash score.sh --json > /tmp/after.json
  6. If improved: commit; else revert
```

## Action Catalog

| Action | Impact | How |
|--------|--------|-----|
| Fix failing tests | +up to 40 pts | Run test command, fix root causes |
| Resolve lint errors | +up to 30 pts | Run lint command, fix each error |
| Increase coverage | +up to 30 pts | Find uncovered lines, write tests |

## Constraints

1. Never remove or skip tests
2. Never use lint suppression comments
3. Never fabricate test results
TMPL
    } > "$PROJECT_PATH/GOAL.md"
    ok "GOAL.md created (template — edit before running the loop)"

    {
      echo "#!/usr/bin/env bash"
      echo "set -euo pipefail"
      echo "SCORE=0; TEST_SCORE=0; LINT_SCORE=0; COV_SCORE=0"
      if [ -n "$TEST_CMD" ]; then
        echo "RESULT=\$(${TEST_CMD} 2>&1 || true)"
        echo "PASS=\$(echo \"\$RESULT\" | grep -oP '\\d+(?= passed)' || echo 0)"
        echo "FAIL=\$(echo \"\$RESULT\" | grep -oP '\\d+(?= failed)' || echo 0)"
        echo "TOTAL=\$(( PASS + FAIL ))"
        echo "[ \"\$TOTAL\" -gt 0 ] && TEST_SCORE=\$(( 40 * PASS / TOTAL )) || TEST_SCORE=0"
      fi
      echo "SCORE=\$(( SCORE + TEST_SCORE ))"
      if [ -n "$LINT_CMD" ]; then
        echo "ISSUE_COUNT=\$(${LINT_CMD} 2>/dev/null | wc -l || echo 0)"
        echo "[ \"\$ISSUE_COUNT\" -eq 0 ] && LINT_SCORE=30 || LINT_SCORE=\$(( 30 > 30 * ISSUE_COUNT / 50 ? 30 - 30 * ISSUE_COUNT / 50 : 0 ))"
      fi
      echo "SCORE=\$(( SCORE + LINT_SCORE ))"
      if [ -n "$COV_CMD" ]; then
        echo "COV=\$(${COV_CMD} 2>/dev/null | grep -oP '\\d+(?=%)' | tail -1 || echo 0)"
        echo "[ \"\$COV\" -ge 80 ] && COV_SCORE=30 || COV_SCORE=\$(( COV >= 50 ? (COV - 50) * 30 / 30 : 0 ))"
      fi
      echo "SCORE=\$(( SCORE + COV_SCORE ))"
      echo "echo \"Tests: \${TEST_SCORE}/40  Lint: \${LINT_SCORE}/30  Coverage: \${COV_SCORE}/30\" >&2"
      echo "echo \"Total: \${SCORE}/100\" >&2"
      echo "if [[ \"\${1:-}\" == \"--json\" ]]; then"
      echo "  echo \"{\\\"score\\\":\$SCORE,\\\"tests\\\":\$TEST_SCORE,\\\"lint\\\":\$LINT_SCORE,\\\"coverage\\\":\$COV_SCORE}\""
      echo "else"
      echo "  echo \"\$SCORE\""
      echo "fi"
    } > "$PROJECT_PATH/score.sh"
    chmod +x "$PROJECT_PATH/score.sh"
    ok "score.sh created (template)"
  fi
fi

if [ ! -f "$PROJECT_PATH/DECISIONS.md" ]; then
  GOAL_TITLE=$(head -1 "$PROJECT_PATH/GOAL.md" | sed 's/^# //')
  cat > "$PROJECT_PATH/DECISIONS.md" << DECEOF
# Workflow Decisions
These decisions are authoritative. Do not contradict them.

1. [USER] Goal: ${GOAL_TITLE}
2. [SYSTEM] Scoring method: bash score.sh (see GOAL.md Fitness Function)
DECEOF
  ok "DECISIONS.md created"
fi

if [ "$PROJECT_PATH" != "$SCRIPT_DIR" ]; then
  echo "PROJECT_PATH=${PROJECT_PATH}" >> .env 2>/dev/null || true
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4: Execution engine (Worker + Reviewer CLIs)
# ══════════════════════════════════════════════════════════════════════════════
hdr "Step 4 of 5 — Execution Engine"
echo ""
echo "  The engine is the agentic CLI that reads goals, edits code, and writes reports."
echo "  It uses the LLM you configured above as its inference backend."
echo ""
echo "  Worker runs the improvement loop. Reviewer writes feedback."
echo ""
echo "  Worker engine:"
echo "    1) codex exec --full-auto   (OpenAI Codex CLI)"
echo "    2) claude --print           (Claude Code CLI)"
echo "    3) skip / configure later"
echo ""
ask "Worker engine [1-3]" WORKER_ENGINE_CHOICE
echo ""
echo "  Reviewer engine:"
echo "    1) claude --print           (Claude Code CLI)"
echo "    2) codex exec --full-auto   (OpenAI Codex CLI)"
echo "    3) skip / configure later"
echo ""
ask "Reviewer engine [1-3]" REVIEWER_ENGINE_CHOICE

case "$WORKER_ENGINE_CHOICE" in
  1) WORKER_TOOL="codex"; WORKER_FLAGS="exec --full-auto" ;;
  2) WORKER_TOOL="claude"; WORKER_FLAGS="--print" ;;
  *) WORKER_TOOL="codex"; WORKER_FLAGS="exec --full-auto" ;;
esac

case "$REVIEWER_ENGINE_CHOICE" in
  1) REVIEWER_TOOL="claude"; REVIEWER_FLAGS="--print" ;;
  2) REVIEWER_TOOL="codex"; REVIEWER_FLAGS="exec --full-auto" ;;
  *) REVIEWER_TOOL="claude"; REVIEWER_FLAGS="--print" ;;
esac

for _tool in "$WORKER_TOOL" "$REVIEWER_TOOL"; do
  if command -v "$_tool" &>/dev/null; then
    ok "$_tool found on PATH"
  else
    err "$_tool not found on PATH — install it before running orchestrate.sh"
  fi
done

echo ""
if [ "$WORKER_TOOL" = "codex" ]; then
  echo "  To connect codex to OpenRouter, create ~/.codex/config.toml:"
  echo "    model_provider = \"openrouter\""
  echo "    model = \"${WORKER_MODEL}\""
  echo "    [model_providers.openrouter]"
  echo "    base_url = \"https://openrouter.ai/api/v1\""
  echo "    env_key = \"OPENROUTER_API_KEY\""
fi
if [ "$REVIEWER_TOOL" = "claude" ] || [ "$WORKER_TOOL" = "claude" ]; then
  echo "  To connect claude-code to OpenRouter, add to your shell profile:"
  echo "    export ANTHROPIC_BASE_URL=https://openrouter.ai/api"
  echo "    export ANTHROPIC_AUTH_TOKEN=\$OPENROUTER_API_KEY"
  echo "    export ANTHROPIC_API_KEY="
fi

ENV_LINES+=(
  "WORKER_TOOL=${WORKER_TOOL}"
  "WORKER_FLAGS=${WORKER_FLAGS}"
  "REVIEWER_TOOL=${REVIEWER_TOOL}"
  "REVIEWER_FLAGS=${REVIEWER_FLAGS}"
)

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5: Notifications (optional)
# ══════════════════════════════════════════════════════════════════════════════
hdr "Step 5 of 5 — Notifications (optional)"
echo ""
echo "  Sends alerts on: loop start, improvement, plateau, completion."
echo "  Press Enter to skip any channel."
echo ""

NOTIF_LINES=()

ask "Slack webhook URL (or Enter to skip)" SLACK_URL
if [ -n "$SLACK_URL" ]; then
  if curl -s -X POST "$SLACK_URL" \
       -H 'Content-type: application/json' \
       -d '{"text":"hephaestus setup test \u2713"}' | grep -q '"ok":true'; then
    ok "Slack"
  else
    err "Slack test failed (saved anyway)"
  fi
  NOTIF_LINES+=("SLACK_WEBHOOK_URL=${SLACK_URL}")
fi

ask "Telegram bot token (or Enter to skip)" TG_TOKEN
if [ -n "$TG_TOKEN" ]; then
  ask "Telegram chat ID" TG_CHAT
  RESP=$(curl -s "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT}" \
    --data-urlencode "text=hephaestus setup test ✓")
  if echo "$RESP" | grep -q '"ok":true'; then ok "Telegram"; else err "Telegram failed (saved anyway)"; fi
  NOTIF_LINES+=("TELEGRAM_BOT_TOKEN=${TG_TOKEN}" "TELEGRAM_CHAT_ID=${TG_CHAT}")
fi

ask "Discord webhook URL (or Enter to skip)" DC_URL
if [ -n "$DC_URL" ]; then
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$DC_URL" \
    -H 'Content-Type: application/json' \
    -d '{"content":"hephaestus setup test \u2713"}')
  if [[ "$HTTP_CODE" =~ ^2 ]]; then ok "Discord"; else err "Discord HTTP $HTTP_CODE (saved anyway)"; fi
  NOTIF_LINES+=("DISCORD_WEBHOOK_URL=${DC_URL}")
fi

# ══════════════════════════════════════════════════════════════════════════════
# Write .env + patch config.yaml
# ══════════════════════════════════════════════════════════════════════════════
hdr "Writing configuration"
echo ""

{
  echo "# Generated by setup.sh"
  echo "# Engine (Worker + Reviewer) — agentic CLI tools"
  echo "# Fuel   (LLM inference)     — API key + model names"
  for line in "${ENV_LINES[@]}" "${NOTIF_LINES[@]}"; do
    echo "$line"
  done
} > .env
ok ".env written"

# Patch config.yaml if it exists
if [ -f config.yaml ] && command -v python3 &>/dev/null && python3 -c "import yaml" 2>/dev/null; then
  python3 - << PYEOF
import re
with open('config.yaml') as f:
    content = f.read()
worker_tool  = '${WORKER_TOOL}'
worker_flags = '${WORKER_FLAGS}'
reviewer_tool  = '${REVIEWER_TOOL}'
reviewer_flags = '${REVIEWER_FLAGS}'
worker_model   = '${WORKER_MODEL}'
reviewer_model = '${REVIEWER_MODEL}'
content = re.sub(r'(agents:\s*\n\s*worker:\s*\n(?:.*\n)*?\s*tool:\s*)\S+', r'\g<1>' + worker_tool, content)
content = re.sub(r'(agents:\s*\n(?:.*\n)*?\s*reviewer:\s*\n(?:.*\n)*?\s*tool:\s*)\S+', r'\g<1>' + reviewer_tool, content)
with open('config.yaml', 'w') as f:
    f.write(content)
PYEOF
  ok "config.yaml patched"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════
hdr "Setup complete"
echo ""
echo "  Project   : $PROJECT_PATH"
echo "  Fuel      : ${OR_BASE_URL} (${GEN_MODEL:-OAuth})"
echo "  Worker    : ${WORKER_TOOL} ${WORKER_FLAGS} → ${WORKER_MODEL}"
echo "  Reviewer  : ${REVIEWER_TOOL} ${REVIEWER_FLAGS} → ${REVIEWER_MODEL}"
echo ""
echo "  Next:"
echo "  1. Review GOAL.md at: $PROJECT_PATH/GOAL.md"
echo "  2. bash $PROJECT_PATH/score.sh — verify baseline score"
echo "  3. ./orchestrate.sh — run the loop"
echo ""
