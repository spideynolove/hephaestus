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
ask() { printf "  %s: " "$1"; read -r "$2"; }
askp() { printf "  %s: " "$1"; read -rs "$2"; echo ""; }

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

if [ "$GOAL_ACTION" = "create" ]; then
  echo ""
  echo "  How would you like to define the goal?"
  echo ""
  echo "  1) AI-assisted  — claude analyzes the project and generates GOAL.md + score.sh"
  echo "  2) Questionnaire — answer a few questions to build GOAL.md step by step"
  echo ""
  ask "Choice [1-2]" GOAL_METHOD

  case "$GOAL_METHOD" in
    1)
      # ── AI-assisted GOAL.md generation ────────────────────────────────────
      echo ""
      echo "  Scanning project at: $PROJECT_PATH"
      echo "  Running claude to analyze and generate GOAL.md + score.sh ..."
      echo ""

      if ! command -v claude &>/dev/null; then
        err "claude CLI not found on PATH — falling back to questionnaire"
        GOAL_METHOD="2"
      else
        AI_PROMPT="You are setting up a hephaestus Worker-Reviewer loop for a software project.

Project directory: ${PROJECT_PATH}

Analyze the project and generate two files:

1. GOAL.md — following the goal-md 5-element format:
   - Fitness Function (bash command that outputs a score 0-100)
   - Operating Mode: Converge, stopping conditions
   - Improvement Loop (step-by-step)
   - Action Catalog (table with Impact and How columns)
   - Constraints
   - Bootstrap section
   - File Map
   - When to Stop report template

2. score.sh — a bash script that:
   - Outputs a single integer 0-100 to stdout
   - Supports --json flag returning {\"score\":N,...}
   - Uses whatever test/lint/coverage tools the project has
   - Writes breakdown to stderr

Output ONLY these two files. Use the format:
=== GOAL.md ===
<content>
=== score.sh ===
<content>

Do not include any other text."

        AI_OUTPUT=$(claude --print "$AI_PROMPT" 2>/dev/null)

        GOAL_CONTENT=$(echo "$AI_OUTPUT" | awk '/^=== GOAL\.md ===$/{f=1;next} /^=== score\.sh ===$/{f=0} f')
        SCORE_CONTENT=$(echo "$AI_OUTPUT" | awk '/^=== score\.sh ===$/{f=1;next} /^===[^=]/{f=0} f')

        if [ -n "$GOAL_CONTENT" ]; then
          echo "$GOAL_CONTENT" > "$PROJECT_PATH/GOAL.md"
          ok "GOAL.md generated"
        else
          err "Could not parse GOAL.md from AI output — falling back to questionnaire"
          GOAL_METHOD="2"
        fi

        if [ -n "$SCORE_CONTENT" ]; then
          echo "$SCORE_CONTENT" > "$PROJECT_PATH/score.sh"
          chmod +x "$PROJECT_PATH/score.sh"
          ok "score.sh generated"
        else
          err "Could not parse score.sh from AI output — will use template"
        fi
      fi
      ;;
  esac

  if [ "$GOAL_METHOD" = "2" ]; then
    # ── Questionnaire GOAL.md generation ──────────────────────────────────
    echo ""
    echo "  Answer the following to build your GOAL.md."
    echo ""

    ask "What is the objective? (e.g. 'bring test coverage above 80%')" GOAL_OBJECTIVE
    ask "Target score [95]" GOAL_TARGET
    GOAL_TARGET="${GOAL_TARGET:-95}"

    echo ""
    echo "  What test runner does this project use?"
    echo "  1) pytest    2) jest/npm test    3) go test    4) other / none"
    ask "Choice [1-4]" TEST_RUNNER_CHOICE

    echo "  What linter?"
    echo "  1) ruff      2) eslint           3) golint     4) other / none"
    ask "Choice [1-4]" LINT_CHOICE

    echo "  What coverage tool?"
    echo "  1) pytest-cov   2) jest --coverage   3) other / none"
    ask "Choice [1-3]" COV_CHOICE

    # Map choices to commands
    case "$TEST_RUNNER_CHOICE" in
      1) TEST_CMD="python -m pytest --tb=no -q" ;;
      2) TEST_CMD="npm test --silent" ;;
      3) TEST_CMD="go test ./... -v" ;;
      *) TEST_CMD="echo 'no test runner configured'" ;;
    esac
    case "$LINT_CHOICE" in
      1) LINT_CMD="ruff check ." ;;
      2) LINT_CMD="npx eslint . --format compact" ;;
      3) LINT_CMD="golint ./..." ;;
      *) LINT_CMD="echo 'no linter configured'" ;;
    esac
    case "$COV_CHOICE" in
      1) COV_CMD="python -m pytest --cov=. --cov-report=term-missing -q" ;;
      2) COV_CMD="npx jest --coverage --coverageReporters=text-summary" ;;
      *) COV_CMD="echo 'no coverage tool configured'" ;;
    esac

    # Write GOAL.md
    cat > "$PROJECT_PATH/GOAL.md" << GOALEOF
# Goal: ${GOAL_OBJECTIVE}

## Fitness Function

\`\`\`bash
bash score.sh
bash score.sh --json
\`\`\`

### Metric Definition

\`\`\`
score = (tests + lint + coverage) / 100
\`\`\`

| Component | Max | What it measures |
|-----------|-----|------------------|
| **Tests** | 40 | All tests pass |
| **Lint** | 30 | Zero lint warnings/errors |
| **Coverage** | 30 | Statement coverage >= 80% |

### Metric Mutability

- [x] **Split** — Agent can improve code but not redefine the success criteria

## Operating Mode

- [x] **Converge** — Stop when criteria met

### Stopping Conditions

- score >= ${GOAL_TARGET}
- 5 consecutive iterations with no improvement → plateau
- 20 iterations completed → timeout
- Tests broken after change → immediate revert

## Bootstrap

1. Ensure dependencies are installed for this project
2. \`bash score.sh\` — record the baseline score
3. \`./orchestrate.sh\` — start the loop

## Improvement Loop

\`\`\`
repeat:
  0. Read logs/iterations.jsonl — note what has been tried
  1. bash score.sh --json > /tmp/before.json
  2. Find the weakest score component
  3. Pick highest-impact action from Action Catalog
  4. Make the change
  5. Run targeted verification
  6. bash score.sh --json > /tmp/after.json
  7. If improved: commit with [S:NN→NN] format
  8. If unchanged/regressed: revert
  9. Append to iterations.jsonl
\`\`\`

Commit format: \`[S:NN→NN] component: what changed\`

## Action Catalog

| Action | Impact | How |
|--------|--------|-----|
| Fix failing tests | +up to 40 pts | Run: \`${TEST_CMD}\`, read failures, fix root cause |
| Resolve lint errors | +up to 30 pts | Run: \`${LINT_CMD}\`, fix each error |
| Increase test coverage | +up to 30 pts | Find uncovered lines, write targeted tests |
| Resolve lint warnings | +5–10 pts | Address remaining warnings after errors are clear |
| Refactor complex functions | +2–5 pts | Reduce cyclomatic complexity |

## Constraints

1. **Never remove or skip tests** — only fix or add
2. **Never use lint suppression comments** — fix the root cause
3. **Never fabricate test results** — run the actual commands

## File Map

| File | Role | Editable? |
|------|------|-----------|
| \`GOAL.md\` | This file | Yes |
| \`score.sh\` | Fitness function | Yes |
| \`COMMENTs.md\` | Reviewer feedback | Written by Reviewer |
| \`SUMMARY.md\` | Worker progress | Written by Worker |
| \`logs/iterations.jsonl\` | Iteration history | Append only |

## When to Stop

\`\`\`
Starting score: NN / 100
Ending score:   NN / 100
Iterations:     N
Exit reason:    target reached / plateau / timeout / test break
Changes made:   (list)
Remaining gaps: (list)
Next actions:   (what to do next)
\`\`\`
GOALEOF
    ok "GOAL.md created"

    # Write score.sh
    cat > "$PROJECT_PATH/score.sh" << SCOREEOF
#!/usr/bin/env bash
set -euo pipefail
SCORE=0
TEST_SCORE=0
LINT_SCORE=0
COV_SCORE=0
DETAILS=""

# Tests (40 pts)
RESULT=\$(${TEST_CMD} 2>&1 || true)
PASS=\$(echo "\$RESULT" | grep -oP '\d+(?= passed)' || echo 0)
FAIL=\$(echo "\$RESULT" | grep -oP '\d+(?= failed)' || echo 0)
TOTAL=\$(( PASS + FAIL ))
if [ "\$TOTAL" -gt 0 ]; then
  TEST_SCORE=\$(( 40 * PASS / TOTAL ))
elif echo "\$RESULT" | grep -qi "passed\|ok\|success"; then
  TEST_SCORE=40
fi
DETAILS="\${DETAILS}tests: \${PASS}/\${TOTAL} (+\${TEST_SCORE})\n"
SCORE=\$(( SCORE + TEST_SCORE ))

# Lint (30 pts)
ISSUE_COUNT=\$(${LINT_CMD} 2>/dev/null | wc -l || echo 0)
if [ "\$ISSUE_COUNT" -eq 0 ]; then
  LINT_SCORE=30
else
  LINT_SCORE=\$(( 30 - (30 * ISSUE_COUNT / 50) ))
  [ "\$LINT_SCORE" -lt 0 ] && LINT_SCORE=0
fi
DETAILS="\${DETAILS}lint: \${ISSUE_COUNT} issues (+\${LINT_SCORE})\n"
SCORE=\$(( SCORE + LINT_SCORE ))

# Coverage (30 pts)
COV=\$(${COV_CMD} 2>/dev/null | grep -oP '\d+(?=%)' | tail -1 || echo 0)
if [ "\$COV" -ge 80 ]; then
  COV_SCORE=30
elif [ "\$COV" -ge 50 ]; then
  COV_SCORE=\$(( (COV - 50) * 30 / 30 ))
fi
DETAILS="\${DETAILS}coverage: \${COV}% (+\${COV_SCORE})\n"
SCORE=\$(( SCORE + COV_SCORE ))

echo -e "Score breakdown:\n\${DETAILS}Total: \${SCORE}/100" >&2
if [[ "\${1:-}" == "--json" ]]; then
  echo "{\\"score\\":\$SCORE,\\"tests\\":\$TEST_SCORE,\\"lint\\":\$LINT_SCORE,\\"coverage\\":\$COV_SCORE}"
else
  echo "\$SCORE"
fi
SCOREEOF
    chmod +x "$PROJECT_PATH/score.sh"
    ok "score.sh created"
  fi
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
