#!/usr/bin/env bash
# setup.sh — Interactive setup wizard for hephaestus
#
# Steps:
#   0. Project + GOAL.md setup (AI-assisted or questionnaire)
#   1. LLM provider selection and API key configuration
#   2. Connection testing
#   3. Notification channel setup (Slack / Telegram / Discord)
#   4. Writing .env and patching config.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Helpers ───────────────────────────────────────────────────────────────────
hr()  { echo ""; echo "────────────────────────────────────────────────"; }
hdr() { hr; echo " $*"; hr; }
ok()  { echo "  ✓ $*"; }
err() { echo "  ✗ $*"; }
ask() { printf "  %s: " "$1"; read -r "$2"; if [ -t 0 ]; then while read -r -t 0.05 _drain; do :; done; fi; }
askp() { printf "  %s: " "$1"; read -rs "$2"; echo ""; if [ -t 0 ]; then while read -r -t 0.05 _drain; do :; done; fi; }

# Invoke the user-selected AI generation tool with a prompt
ai_run_prompt() {
  local _prompt="$1"
  local _base
  _base=$(echo "$GEN_TOOL" | awk '{print $1}')
  case "$_base" in
    claude)  claude --print "$_prompt" 2>/dev/null ;;
    codex)   codex "$_prompt" 2>/dev/null ;;
    gemini)  gemini "$_prompt" 2>/dev/null ;;
    qwen)    qwen "$_prompt" 2>/dev/null ;;
    kimi)    kimi "$_prompt" 2>/dev/null ;;
    *)       $GEN_TOOL "$_prompt" 2>/dev/null ;;
  esac
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
# STEP 0: Project + GOAL.md
# ══════════════════════════════════════════════════════════════════════════════
hdr "Step 0 of 4 — Project & Goal"
echo ""
echo "  The loop needs to know what project to improve and what 'good' looks like."
echo ""

ask "Path to the project you want to improve [$(pwd)]" PROJECT_PATH
PROJECT_PATH="${PROJECT_PATH:-$(pwd)}"
PROJECT_PATH="$(realpath "$PROJECT_PATH")"

if [ ! -d "$PROJECT_PATH" ]; then
  echo "  Directory not found: $PROJECT_PATH"
  exit 1
fi
ok "Project: $PROJECT_PATH"

# Check if project has a GOAL.md already
GOAL_ACTION="create"
if [ -f "$PROJECT_PATH/GOAL.md" ]; then
  echo ""
  echo "  GOAL.md already exists in that project."
  echo ""
  echo "  1) Keep existing GOAL.md"
  echo "  2) Regenerate it"
  echo ""
  ask "Choice [1-2]" GOAL_ACTION_CHOICE
  [[ "$GOAL_ACTION_CHOICE" == "2" ]] && GOAL_ACTION="create" || GOAL_ACTION="keep"
fi

# ── Detect AI CLI for GOAL generation ────────────────────────────────────────
echo ""
echo "  Which AI CLI tool should generate GOAL.md and score.sh?"
echo ""

_avail=()
for _t in claude codex gemini qwen kimi; do
  command -v "$_t" &>/dev/null && _avail+=("$_t ✓") || true
done
if [ ${#_avail[@]} -gt 0 ]; then
  echo "  Detected on PATH: ${_avail[*]}"
else
  echo "  No known AI CLI tools detected on PATH."
fi
echo ""
echo "  1) claude   2) codex   3) gemini   4) qwen   5) kimi"
echo "  6) custom   (you specify the command prefix)"
echo "  7) skip     (use template, edit manually)"
echo ""
ask "Choice [1-7]" _GEN_CHOICE

case "$_GEN_CHOICE" in
  1) GEN_TOOL="claude" ;;
  2) GEN_TOOL="codex" ;;
  3) GEN_TOOL="gemini" ;;
  4) GEN_TOOL="qwen" ;;
  5) GEN_TOOL="kimi" ;;
  6) ask "Command prefix (prompt appended as last arg, e.g. 'mycli --print')" GEN_TOOL ;;
  *) GEN_TOOL="skip" ;;
esac

if [ "$GEN_TOOL" != "skip" ]; then
  _base=$(echo "$GEN_TOOL" | awk '{print $1}')
  if ! command -v "$_base" &>/dev/null; then
    err "$GEN_TOOL not found on PATH — will use template fallback"
    GEN_TOOL="skip"
  else
    ok "Using $GEN_TOOL for generation"
  fi
fi

if [ "$GOAL_ACTION" = "create" ]; then
  echo ""
  echo "  Paste your goal / analysis below (or just press Enter to let AI analyze the project)."
  echo "  Enter a blank line when done."
  echo ""
  printf "  Goal context (blank line to finish):\n"

  USER_CONTEXT=""
  while IFS= read -r _ctx_line || true; do
    [[ -z "$_ctx_line" ]] && break
    USER_CONTEXT="${USER_CONTEXT}${_ctx_line}"$'\n'
  done

  echo ""

  # ── AI-assisted generation (primary path) ────────────────────────────────
  AI_GENERATED=false
  if [ "$GEN_TOOL" != "skip" ]; then
    echo "  Analyzing project via $GEN_TOOL — generating GOAL.md + score.sh ..."
    echo ""

    _ctx_section=""
    if [ -n "$USER_CONTEXT" ]; then
      _ctx_section="The user has provided the following goal/analysis as context. Use it to drive the fitness function, action catalog, and scoring logic — do not ignore it:

${USER_CONTEXT}
---
"
    fi

    AI_PROMPT=$(cat << AIPROMPT_EOF
IMPORTANT: This is a plain-text generation task. Do NOT write any files. Do NOT use any tools. Your entire response must be raw text only.

You are generating configuration for a hephaestus Worker-Reviewer loop.

Project directory: ${PROJECT_PATH}

${_ctx_section}Read the project files at that directory to understand its language, test runner, linter, and coverage tools. Then respond with ONLY the two file contents below — no preamble, no explanation, no tool calls.

=== GOAL.md ===
A GOAL.md tailored to this specific project with:
- Fitness function grounded in what this project actually measures
- Concrete stopping conditions and target score
- Improvement Loop (step-by-step)
- Action Catalog with specific actionable items for this project's actual gaps
- Constraints from the project's actual requirements

=== score.sh ===
A bash script that:
- Starts with #!/usr/bin/env bash
- Outputs a single integer 0-100 to stdout
- Accepts --json flag returning {"score":N,"tests":N,"lint":N,"coverage":N}
- Uses the ACTUAL commands for this project (detect from pyproject.toml / package.json / Makefile / setup.cfg)
- Writes score breakdown to stderr
- Contains only real executable commands, never placeholder echo statements

Respond now with only the two sections above, starting with the line: === GOAL.md ===
AIPROMPT_EOF
)

    # Gather project context to include in prompt (avoids needing tool access)
    _proj_context=""
    _proj_context="${_proj_context}Directory listing (2 levels):\n$(ls -la "$PROJECT_PATH" 2>/dev/null)\n\n"
    for _cfg in pyproject.toml setup.cfg setup.py package.json go.mod Cargo.toml Makefile requirements.txt; do
      if [ -f "$PROJECT_PATH/$_cfg" ]; then
        _proj_context="${_proj_context}=== $_cfg ===\n$(head -60 "$PROJECT_PATH/$_cfg")\n\n"
      fi
    done
    # Include first test file found for context
    _test_file=$(find "$PROJECT_PATH" -maxdepth 3 -name "test_*.py" -o -name "*.test.ts" -o -name "*.spec.js" 2>/dev/null | head -1)
    if [ -n "$_test_file" ]; then
      _proj_context="${_proj_context}=== sample test file: $_test_file ===\n$(head -30 "$_test_file")\n\n"
    fi
    AI_PROMPT=$(printf '%s

Project context collected from disk:
%b' "$AI_PROMPT" "$_proj_context")

    AI_OUTPUT=$(ai_run_prompt "$AI_PROMPT")

    GOAL_CONTENT=$(echo "$AI_OUTPUT" | awk '/^=== GOAL\.md ===$/{f=1;next} /^=== score\.sh ===$/{f=0} f')
    SCORE_CONTENT=$(echo "$AI_OUTPUT" | awk '/^=== score\.sh ===$/{f=1;next} /^===[^=]/{f=0} f')

    if [ -n "$GOAL_CONTENT" ]; then
      printf '%s\n' "$GOAL_CONTENT" > "$PROJECT_PATH/GOAL.md"
      ok "GOAL.md generated"
      AI_GENERATED=true
    else
      err "Could not parse GOAL.md from AI output — falling back to template"
    fi

    if [ -n "$SCORE_CONTENT" ]; then
      printf '%s\n' "$SCORE_CONTENT" > "$PROJECT_PATH/score.sh"
      chmod +x "$PROJECT_PATH/score.sh"
      ok "score.sh generated"
    else
      err "Could not parse score.sh from AI output — will use template"
    fi
  else
    err "No AI tool selected or available — using template fallback"
  fi

  # ── Template fallback (only when AI unavailable or failed) ───────────────
  if ! $AI_GENERATED; then
    GOAL_OBJECTIVE=$(printf '%s' "$USER_CONTEXT" | head -1)
    GOAL_OBJECTIVE="${GOAL_OBJECTIVE:-improve this project}"

    echo ""
    echo "  No AI tool available. Collecting tool info for score.sh template."
    echo ""
    echo "  What test runner does this project use?"
    echo "  1) pytest    2) jest/npm test    3) go test    4) other / none"
    ask "Choice [1-4]" TEST_RUNNER_CHOICE
    echo "  What linter?"
    echo "  1) ruff      2) eslint    3) golint    4) other / none"
    ask "Choice [1-4]" LINT_CHOICE
    echo "  What coverage tool?"
    echo "  1) pytest-cov    2) jest --coverage    3) other / none"
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
      if [ -n "$USER_CONTEXT" ]; then
        echo "## Context"
        echo ""
        printf '%s\n' "$USER_CONTEXT"
      fi
      cat << 'TMPL'
## Fitness Function

```bash
bash score.sh
bash score.sh --json
```

## Operating Mode

- [x] **Converge** — Stop when score >= target

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
      echo "SCORE=0; TEST_SCORE=0; LINT_SCORE=0; COV_SCORE=0; DETAILS=\"\""
      if [ -n "$TEST_CMD" ]; then
        echo "RESULT=\$(${TEST_CMD} 2>&1 || true)"
        echo "PASS=\$(echo \"\$RESULT\" | grep -oP '\\d+(?= passed)' || echo 0)"
        echo "FAIL=\$(echo \"\$RESULT\" | grep -oP '\\d+(?= failed)' || echo 0)"
        echo "TOTAL=\$(( PASS + FAIL ))"
        echo "if [ \"\$TOTAL\" -gt 0 ]; then TEST_SCORE=\$(( 40 * PASS / TOTAL ))"
        echo "elif echo \"\$RESULT\" | grep -qi 'passed\\|ok\\|success'; then TEST_SCORE=40; fi"
      fi
      echo "DETAILS=\"\${DETAILS}tests: \${PASS:-0}/\${TOTAL:-0} (+\${TEST_SCORE})\\n\""
      echo "SCORE=\$(( SCORE + TEST_SCORE ))"
      if [ -n "$LINT_CMD" ]; then
        echo "ISSUE_COUNT=\$(${LINT_CMD} 2>/dev/null | wc -l || echo 0)"
        echo "if [ \"\$ISSUE_COUNT\" -eq 0 ]; then LINT_SCORE=30"
        echo "else LINT_SCORE=\$(( 30 - (30 * ISSUE_COUNT / 50) )); [ \"\$LINT_SCORE\" -lt 0 ] && LINT_SCORE=0; fi"
      fi
      echo "DETAILS=\"\${DETAILS}lint: \${ISSUE_COUNT:-0} issues (+\${LINT_SCORE})\\n\""
      echo "SCORE=\$(( SCORE + LINT_SCORE ))"
      if [ -n "$COV_CMD" ]; then
        echo "COV=\$(${COV_CMD} 2>/dev/null | grep -oP '\\d+(?=%)' | tail -1 || echo 0)"
        echo "if [ \"\$COV\" -ge 80 ]; then COV_SCORE=30"
        echo "elif [ \"\$COV\" -ge 50 ]; then COV_SCORE=\$(( (COV - 50) * 30 / 30 )); fi"
      fi
      echo "DETAILS=\"\${DETAILS}coverage: \${COV:-0}% (+\${COV_SCORE})\\n\""
      echo "SCORE=\$(( SCORE + COV_SCORE ))"
      echo "echo -e \"Score breakdown:\\n\${DETAILS}Total: \${SCORE}/100\" >&2"
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

# If project is different from hephaestus dir, note it
if [ "$PROJECT_PATH" != "$SCRIPT_DIR" ]; then
  echo ""
  echo "  Note: Your project is at: $PROJECT_PATH"
  echo "  The loop will run from: $SCRIPT_DIR"
  echo "  orchestrate.sh will pass the full project path to agents via the prompt."
  echo ""
  # Write project path to config
  echo "PROJECT_PATH=${PROJECT_PATH}" >> .env 2>/dev/null || true
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1: Choose provider
# ══════════════════════════════════════════════════════════════════════════════
hdr "Step 1 of 4 — Choose your LLM provider"
echo ""
echo "  1) OAuth subscription     (claude-code + codex, no API keys needed)"
echo "  2) OpenRouter free        (rate-limited ~200 req/day, no cost)"
echo "  3) DeepSeek               (paid — fast and cheap)"
echo "  4) Z.AI / GLM             (paid — Worker falls back to claude)"
echo "  5) Anthropic + OpenAI     (official API keys)"
echo "  6) Custom endpoint        (any OpenAI-compatible proxy)"
echo ""
ask "Enter choice [1-6]" PROVIDER_CHOICE

# ── Step 2: Collect credentials ───────────────────────────────────────────────
hdr "Step 2 of 4 — Enter credentials"

ENV_LINES=()
WORKER_TOOL_OVERRIDE=""

case "$PROVIDER_CHOICE" in
  1)
    echo ""
    echo "  OAuth mode: no API keys needed."
    WORKER_TOOL_OVERRIDE="claude"
    ENV_LINES+=("WORKER_TOOL_OVERRIDE=claude")
    ;;
  2)
    echo ""
    echo "  Get your key at https://openrouter.ai/keys"
    echo ""
    askp "OpenRouter API key (sk-or-v1-...)" OR_KEY
    ENV_LINES+=(
      "ANTHROPIC_BASE_URL=https://openrouter.ai/api"
      "ANTHROPIC_AUTH_TOKEN=${OR_KEY}"
      "OPENAI_BASE_URL=https://openrouter.ai/api/v1"
      "OPENAI_API_KEY=${OR_KEY}"
      "WORKER_MODEL=qwen/qwen3-coder-480b:free"
      "REVIEWER_MODEL=deepseek/deepseek-r1:free"
    )
    ;;
  3)
    echo ""
    echo "  Get your key at https://platform.deepseek.com/api_keys"
    echo ""
    askp "DeepSeek API key" DS_KEY
    ENV_LINES+=(
      "ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic"
      "ANTHROPIC_AUTH_TOKEN=${DS_KEY}"
      "OPENAI_BASE_URL=https://api.deepseek.com"
      "OPENAI_API_KEY=${DS_KEY}"
      "WORKER_MODEL=deepseek-chat"
      "REVIEWER_MODEL=deepseek-chat"
    )
    ;;
  4)
    echo ""
    echo "  Get your key at https://open.bigmodel.cn/usercenter/apikeys"
    echo "  Worker falls back to claude (OAuth or API key)."
    echo ""
    askp "Z.AI / GLM API key" ZAI_KEY
    ENV_LINES+=(
      "ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic"
      "ANTHROPIC_AUTH_TOKEN=${ZAI_KEY}"
      "WORKER_TOOL_OVERRIDE=claude"
      "REVIEWER_MODEL=glm-5.1"
    )
    WORKER_TOOL_OVERRIDE="claude"
    ;;
  5)
    echo ""
    askp "Anthropic API key (sk-ant-...)" ANT_KEY
    askp "OpenAI API key (sk-...)" OAI_KEY
    ENV_LINES+=(
      "ANTHROPIC_API_KEY=${ANT_KEY}"
      "OPENAI_API_KEY=${OAI_KEY}"
    )
    ;;
  6)
    echo ""
    ask "Anthropic-compatible base URL" CUSTOM_ANT_URL
    askp "Auth token for Anthropic endpoint" CUSTOM_ANT_KEY
    ask "OpenAI-compatible base URL" CUSTOM_OAI_URL
    askp "API key for OpenAI endpoint" CUSTOM_OAI_KEY
    ENV_LINES+=(
      "ANTHROPIC_BASE_URL=${CUSTOM_ANT_URL}"
      "ANTHROPIC_AUTH_TOKEN=${CUSTOM_ANT_KEY}"
      "OPENAI_BASE_URL=${CUSTOM_OAI_URL}"
      "OPENAI_API_KEY=${CUSTOM_OAI_KEY}"
    )
    ;;
  *)
    echo "Invalid choice. Exiting."
    exit 1
    ;;
esac

# ── Step 2b: Test connections ──────────────────────────────────────────────────
echo ""
echo "  Testing connections..."
echo ""

for line in "${ENV_LINES[@]}"; do
  export "${line?}" 2>/dev/null || true
done

CLAUDE_OK=false
if command -v claude &>/dev/null; then
  if claude --print "respond with exactly: ok" 2>/dev/null | grep -qi "ok"; then
    ok "claude CLI"
    CLAUDE_OK=true
  else
    err "claude CLI — check ANTHROPIC_BASE_URL / auth / OAuth session"
  fi
else
  err "claude not found on PATH"
fi

CODEX_OK=false
if [[ "$WORKER_TOOL_OVERRIDE" == "claude" ]]; then
  ok "codex — skipped (using claude as Worker)"
  CODEX_OK=true
elif command -v codex &>/dev/null; then
  if codex exec --full-auto "echo ok" 2>/dev/null | grep -qi "ok"; then
    ok "codex CLI"
    CODEX_OK=true
  else
    err "codex CLI — check OPENAI_BASE_URL / OPENAI_API_KEY"
  fi
else
  err "codex not found on PATH"
fi

if ! $CLAUDE_OK || ! $CODEX_OK; then
  echo ""
  ask "One or more tests failed. Continue anyway? [y/N]" CONT
  [[ "$CONT" =~ ^[Yy]$ ]] || { echo "  Aborted."; exit 1; }
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3: Notifications
# ══════════════════════════════════════════════════════════════════════════════
hdr "Step 3 of 4 — Notifications (optional)"
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
  if echo "$RESP" | grep -q '"ok":true'; then
    ok "Telegram"
  else
    err "Telegram failed (saved anyway)"
  fi
  NOTIF_LINES+=("TELEGRAM_BOT_TOKEN=${TG_TOKEN}" "TELEGRAM_CHAT_ID=${TG_CHAT}")
fi

ask "Discord webhook URL (or Enter to skip)" DC_URL
if [ -n "$DC_URL" ]; then
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$DC_URL" \
    -H 'Content-Type: application/json' \
    -d '{"content":"hephaestus setup test \u2713"}')
  if [[ "$HTTP_CODE" =~ ^2 ]]; then
    ok "Discord"
  else
    err "Discord HTTP $HTTP_CODE (saved anyway)"
  fi
  NOTIF_LINES+=("DISCORD_WEBHOOK_URL=${DC_URL}")
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4: Write config
# ══════════════════════════════════════════════════════════════════════════════
hdr "Step 4 of 4 — Writing configuration"
echo ""

cat > .env << 'ENVEOF'
# Generated by setup.sh
ENVEOF

for line in "${ENV_LINES[@]}" "${NOTIF_LINES[@]}"; do
  echo "$line" >> .env
done

ok ".env written"

if [ -n "$WORKER_TOOL_OVERRIDE" ] && command -v python3 &>/dev/null && python3 -c "import yaml" 2>/dev/null; then
  python3 - << PYEOF
import re
with open('config.yaml') as f:
    content = f.read()
content = re.sub(r'(tool:\s*)codex', r'\1claude', content)
content = re.sub(r'(flags:\s*)"exec --full-auto[^"]*"', r'\1"--print"', content)
with open('config.yaml', 'w') as f:
    f.write(content)
PYEOF
  ok "config.yaml patched (Worker → claude)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════
hdr "Setup complete"
echo ""
echo "  Project  : $PROJECT_PATH"
echo "  Provider : $([ "$PROVIDER_CHOICE" = "1" ] && echo "OAuth subscription" || \
                     [ "$PROVIDER_CHOICE" = "2" ] && echo "OpenRouter free" || \
                     [ "$PROVIDER_CHOICE" = "3" ] && echo "DeepSeek" || \
                     [ "$PROVIDER_CHOICE" = "4" ] && echo "Z.AI / GLM" || \
                     [ "$PROVIDER_CHOICE" = "5" ] && echo "Official Anthropic + OpenAI" || \
                     echo "Custom endpoint")"
echo "  Worker   : ${WORKER_TOOL_OVERRIDE:-codex}"
echo ""
echo "  Next:"
echo "  1. Review GOAL.md at: $PROJECT_PATH/GOAL.md"
echo "  2. bash score.sh — verify baseline score"
echo "  3. ./orchestrate.sh — run the loop"
echo ""
