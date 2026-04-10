#!/usr/bin/env bash
# orchestrate.sh — Automated Worker↔Reviewer loop
#
# Usage:
#   ./orchestrate.sh                  # run with config.yaml defaults
#   ./orchestrate.sh --max-iter 5     # override max iterations
#   ./orchestrate.sh --target 80      # override target score
#   ./orchestrate.sh --dry-run        # print commands without executing
#
# Environment (set via setup.sh or .env):
#   PROJECT_PATH — path to the project being improved (default: current dir)

set -euo pipefail

# ── Recursion guard ───────────────────────────────────────────────────────────
if [ -n "${HEPHAESTUS_RUNNING:-}" ]; then
  echo "ERROR: orchestrate.sh called recursively — aborting." >&2
  exit 1
fi
export HEPHAESTUS_RUNNING=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Activate installer-managed venv (provides pyyaml, avoids PEP 668) ────────
if [ -f "$SCRIPT_DIR/.venv/bin/activate" ]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/.venv/bin/activate"
fi

# ── Load environment ──────────────────────────────────────────────────────────
[ -f "$SCRIPT_DIR/.env" ] && source "$SCRIPT_DIR/.env"

# ── Resolve project path ──────────────────────────────────────────────────────
PROJECT_PATH="${PROJECT_PATH:-$SCRIPT_DIR}"
PROJECT_PATH="$(realpath "$PROJECT_PATH")"
PROJECT_NAME="$(basename "$PROJECT_PATH")"
LOG_DIR="$SCRIPT_DIR/logs/$PROJECT_NAME"

# All file operations (GOAL.md, score.sh, COMMENTs.md, SUMMARY.md, git) happen here
cd "$PROJECT_PATH"

# ── Parse config.yaml (requires python3 + pyyaml) ────────────────────────────
_cfg() {
  python3 -c "
import yaml
with open('$SCRIPT_DIR/config.yaml') as f:
    d = yaml.safe_load(f)
keys = '$1'.split('.')
v = d
for k in keys:
    v = v[k]
print(v)
" 2>/dev/null || echo "$2"
}

# ── Config: .env values (written by setup.sh) take priority over config.yaml ──
MAX_ITER=$(_cfg loop.max_iterations 20)
NO_IMPROVE_LIMIT=$(_cfg loop.no_improve_limit 5)
TARGET_SCORE=$(_cfg loop.target_score 95)
REVERT_ON_REGRESSION=$(_cfg loop.revert_on_regression true)

# WORKER_TOOL / WORKER_FLAGS / REVIEWER_TOOL / REVIEWER_FLAGS are set by setup.sh
# into .env and sourced above. Only fall back to config.yaml when not set.
WORKER_TOOL="${WORKER_TOOL:-$(_cfg agents.worker.tool codex)}"
WORKER_FLAGS="${WORKER_FLAGS:-$(_cfg agents.worker.flags 'exec --full-auto')}"
WORKER_ROLE=$(_cfg agents.worker.role_description "Read GOAL.md and COMMENTs.md. Apply improvements. Write progress to SUMMARY.md.")

REVIEWER_TOOL="${REVIEWER_TOOL:-$(_cfg agents.reviewer.tool claude)}"
REVIEWER_FLAGS="${REVIEWER_FLAGS:-$(_cfg agents.reviewer.flags '--print')}"
REVIEWER_ROLE=$(_cfg agents.reviewer.role_description "Read SUMMARY.md and GOAL.md. Write feedback to COMMENTs.md.")

# ── Argument overrides ────────────────────────────────────────────────────────
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-iter) MAX_ITER="$2"; shift 2 ;;
    --target)   TARGET_SCORE="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=true; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { echo "[$(date -u +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

run() {
  if $DRY_RUN; then
    echo "  [DRY-RUN] $*"
  else
    eval "$*"
  fi
}

notify() {
  local msg="$1"
  log "$msg"
  if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
    curl -s -X POST "$SLACK_WEBHOOK_URL" \
      -H 'Content-type: application/json' \
      -d "{\"text\": \"[$PROJECT_NAME] $msg\"}" >/dev/null 2>&1 || true
  fi
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=[$PROJECT_NAME] $msg" >/dev/null 2>&1 || true
  fi
  if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
    curl -s -X POST "$DISCORD_WEBHOOK_URL" \
      -H 'Content-Type: application/json' \
      -d "{\"content\": \"[$PROJECT_NAME] $msg\"}" >/dev/null 2>&1 || true
  fi
}

# ── Memory management ─────────────────────────────────────────────────────────
update_memory() {
  local ts_now
  ts_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local trajectory
  trajectory=$(tail -10 "$LOG_DIR/iterations.jsonl" 2>/dev/null \
    | python3 -c "
import sys, json
print('| # | Score | Delta | Result | Action |')
print('|---|-------|-------|--------|--------|')
for line in sys.stdin:
    try:
        d = json.loads(line.strip())
        action = d.get('action','?')[:40]
        print(f\"| {d['iteration']} | {d['after']} | {d['delta']:+d} | {d['result']} | {action} |\")
    except (json.JSONDecodeError, KeyError):
        pass
" 2>/dev/null || echo "(no trajectory data)")

  local action_brief
  action_brief=$(head -1 SUMMARY.md 2>/dev/null | head -c 80 || echo "no summary")
  local tried_entry=""
  if [ -n "$action_brief" ] && [ "$action_brief" != "no summary" ]; then
    if $kept; then
      tried_entry="- [KEPT] ${action_brief} (score ${prev_score} -> ${score})"
    else
      tried_entry="- [REVERTED] ${action_brief} (score stayed at ${score})"
    fi
  fi

  local weakest
  weakest=$(echo "$score_json" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    components = {k:v for k,v in d.items() if k != 'score'}
    if components:
        weakest = min(components, key=components.get)
        print(f'{weakest} ({components[weakest]})')
    else:
        print('unknown')
except (json.JSONDecodeError, ValueError):
    print('unknown')
" 2>/dev/null || echo "unknown")

  local status="RUNNING"
  (( no_improve_count >= NO_IMPROVE_LIMIT )) && status="STUCK"
  (( score >= TARGET_SCORE )) && status="COMPLETE"

  local next_action
  next_action=$(grep -m1 -i 'priority\|next action\|most important\|highest-impact' COMMENTs.md 2>/dev/null \
    | head -c 120 || echo "Follow COMMENTs.md instructions")

  local tried_section=""
  if [ -f "$MEMORY_FILE" ]; then
    tried_section=$(sed -n '/^## What Has Been Tried/,/^## /{ /^## What Has Been Tried/d; /^## /q; p }' "$MEMORY_FILE" \
      | head -15)
  fi
  local blocked_section=""
  if [ -f "$MEMORY_FILE" ]; then
    blocked_section=$(sed -n '/^## Blocked/,${ p }' "$MEMORY_FILE" | tail -n +2 | head -10)
  fi

  cat > "$MEMORY_FILE" << MEMEOF
# Workflow Memory
Last updated: ${ts_now}
Session: ${SESSION_TS} | Total iterations across all sessions: ${TOTAL_ITERATIONS}

## Current State
- Score: ${score}/100 (best ever: ${best_score})
- Status: ${status}
- Goal target: ${TARGET_SCORE}
- No-improve streak: ${no_improve_count}/${NO_IMPROVE_LIMIT}

## Score Trajectory (last 10 iterations)
${trajectory}

## What Has Been Tried
${tried_section}
${tried_entry}

## Key Observations
- Weakest component: ${weakest}
- Score breakdown: ${score_json}

## Next Priority Actions
1. ${next_action}

## Blocked / Do Not Attempt
${blocked_section}
MEMEOF

  if (( $(wc -l < "$MEMORY_FILE") > MEMORY_MAX_LINES )); then
    head -"$MEMORY_MAX_LINES" "$MEMORY_FILE" > "$MEMORY_FILE.tmp" && mv "$MEMORY_FILE.tmp" "$MEMORY_FILE"
    log "MEMORY.md capped at ${MEMORY_MAX_LINES} lines"
  fi

  log "MEMORY.md updated (${ts_now})"
}

# ── Pre-flight checks ─────────────────────────────────────────────────────────
[ -f GOAL.md ]  || die "GOAL.md not found in $PROJECT_PATH. Run: bash $SCRIPT_DIR/setup.sh"
[ -f score.sh ] || die "score.sh not found in $PROJECT_PATH. Run: bash $SCRIPT_DIR/setup.sh"
[ -x score.sh ] || chmod +x score.sh
if ! $DRY_RUN; then
  # Use `type` to detect both binaries on PATH and shell functions (deepseek, glm, qwen, etc.)
  type "$WORKER_TOOL"   &>/dev/null || log "WARNING: $WORKER_TOOL not found — will fail at runtime if not a shell function"
  type "$REVIEWER_TOOL" &>/dev/null || log "WARNING: $REVIEWER_TOOL not found — will fail at runtime if not a shell function"
fi
command -v python3 &>/dev/null || die "python3 required for config parsing."
if ! python3 -c "import yaml" 2>/dev/null; then
  log "WARNING: pyyaml not found — using built-in defaults (run install.sh to fix)"
fi

mkdir -p "$LOG_DIR"

# ── Write session metadata ────────────────────────────────────────────────────
SESSION_TS=$(date -u +%Y%m%dT%H%M%SZ)
if ! $DRY_RUN; then
  GOAL_EXCERPT=$(head -5 GOAL.md | tr '\n' ' ' | sed 's/"/\\"/g')
  cat > "$LOG_DIR/session-${SESSION_TS}.json" << EOF
{
  "session_ts": "${SESSION_TS}",
  "project": "${PROJECT_NAME}",
  "project_dir": "${PROJECT_PATH}",
  "worker_tool": "${WORKER_TOOL}",
  "reviewer_tool": "${REVIEWER_TOOL}",
  "target_score": ${TARGET_SCORE},
  "max_iter": ${MAX_ITER},
  "goal_excerpt": "${GOAL_EXCERPT}"
}
EOF
  ln -sf "$LOG_DIR/session-${SESSION_TS}.json" "$LOG_DIR/session-latest.json"
fi

touch "$LOG_DIR/iterations.jsonl"

# ── State ─────────────────────────────────────────────────────────────────────
STATE_FILE="$PROJECT_PATH/STATE.sh"
MEMORY_FILE="$PROJECT_PATH/MEMORY.md"
DECISIONS_FILE="$PROJECT_PATH/DECISIONS.md"
MEMORY_MAX_LINES=$(_cfg loop.memory_max_lines 80)
score=0
best_score=0
prev_score=0
no_improve_count=0
exit_code=0
iter=0
TOTAL_ITERATIONS=0
EMPTY_SUMMARY_COUNT=0
CONDENSE_MODE=false

if [ -f "$STATE_FILE" ]; then
  source "$STATE_FILE" 2>/dev/null || log "WARNING: corrupt STATE.sh — starting fresh"
  if [ "${HEPH_STATE_VERSION:-0}" != "1" ]; then
    log "WARNING: STATE.sh version mismatch — starting fresh"
    score=0; best_score=0; TOTAL_ITERATIONS=0; no_improve_count=0
  else
    score=${HEPH_CURRENT_SCORE:-0}
    best_score=${HEPH_BEST_SCORE:-0}
    prev_score=${HEPH_CURRENT_SCORE:-0}
    no_improve_count=${HEPH_NO_IMPROVE_COUNT:-0}
    TOTAL_ITERATIONS=${HEPH_TOTAL_ITERATIONS:-0}
    log "Restored state from STATE.sh (best_score=$best_score, total_iters=$TOTAL_ITERATIONS)"
  fi
fi

# ── Seed COMMENTs.md if empty ─────────────────────────────────────────────────
if [ ! -s COMMENTs.md ]; then
  cat > COMMENTs.md << 'EOF'
# Initial Task

Read GOAL.md for the full objective and constraints.

**First iteration:** Assess the current state of the codebase against the
fitness function in GOAL.md. Pick the highest-impact action from the Action
Catalog and apply it. Report what you changed in SUMMARY.md.
EOF
fi

# ── Seed MEMORY.md if missing ────────────────────────────────────────────────
if [ ! -f "$MEMORY_FILE" ]; then
  cat > "$MEMORY_FILE" << 'MEMEOF'
# Workflow Memory
Last updated: (not yet)
Session: (not yet) | Total iterations across all sessions: 0

## Current State
- Score: (unknown) / 100 (best ever: 0)
- Status: STARTING
- Goal target: 95

## Score Trajectory (last 10 iterations)
| # | Score | Delta | Result | Action |
|---|-------|-------|--------|--------|
| (no iterations yet) |

## What Has Been Tried
- (nothing yet)

## Key Observations
- (awaiting first scoring run)

## Next Priority Actions
1. Run score.sh to establish baseline
2. Follow COMMENTs.md initial instructions

## Blocked / Do Not Attempt
- (nothing yet)
MEMEOF
  log "Created MEMORY.md"
fi

# ── Seed DECISIONS.md if missing ──────────────────────────────────────────────
if [ ! -f "$DECISIONS_FILE" ]; then
  GOAL_TITLE=$(head -1 GOAL.md | sed 's/^# //')
  cat > "$DECISIONS_FILE" << DECEOF
# Workflow Decisions
These decisions are authoritative. Do not contradict them.

1. [USER] Goal: ${GOAL_TITLE}
2. [SYSTEM] Scoring method: bash score.sh (see GOAL.md Fitness Function)
DECEOF
  log "Created DECISIONS.md"
fi
log "Project      : $PROJECT_NAME ($PROJECT_PATH)"
log "Logs         : $LOG_DIR"
log "Starting loop | target=$TARGET_SCORE max_iter=$MAX_ITER no_improve_limit=$NO_IMPROVE_LIMIT"
notify "Loop started | target=${TARGET_SCORE}/100"

for iter in $(seq 1 "$MAX_ITER"); do
  log "━━━ Iteration $iter / $MAX_ITER ━━━"

  # ── WORKER step ──────────────────────────────────────────────────────────
  log "Worker ($WORKER_TOOL) starting..."

  if [ ! -f SUMMARY.md ] || [ ! -s SUMMARY.md ]; then
    EMPTY_SUMMARY_COUNT=$(( EMPTY_SUMMARY_COUNT + 1 ))
  else
    EMPTY_SUMMARY_COUNT=0
  fi

  CONDENSE_THRESHOLD=$(_cfg loop.condense_after_empty 3)
  if (( EMPTY_SUMMARY_COUNT >= CONDENSE_THRESHOLD )) && (( CONDENSE_THRESHOLD > 0 )); then
    CONDENSE_MODE=true
    log "Condensation active (${EMPTY_SUMMARY_COUNT} empty summaries)"
  else
    CONDENSE_MODE=false
  fi

  WORKER_ROLE_EXPANDED="$(echo "$WORKER_ROLE" | sed "s|{SCORE}|${best_score}|g; s|{TARGET}|${TARGET_SCORE}|g")"

  if $CONDENSE_MODE; then
    FULL_WORKER_PROMPT="You are the Worker. Read GOAL.md and COMMENTs.md in the project directory.
Apply the single most important improvement. Write a brief SUMMARY.md when done.
Project: ${PROJECT_PATH}
Current score: ${score}/${TARGET_SCORE}.
$(grep -A3 '## Next Priority' "$MEMORY_FILE" 2>/dev/null | head -3 || echo 'Follow COMMENTs.md instructions')"
  else
    MEMORY_CONTENT="$(cat "$MEMORY_FILE" 2>/dev/null || echo '(no memory)')"
    DECISIONS_CONTENT="$(cat "$DECISIONS_FILE" 2>/dev/null || echo '(none)')"
    FULL_WORKER_PROMPT="${WORKER_ROLE_EXPANDED}

Project directory: ${PROJECT_PATH}

---
WORKFLOW DECISIONS (authoritative — do not contradict):
${DECISIONS_CONTENT}

---
WORKFLOW MEMORY (where we are, what's been tried):
${MEMORY_CONTENT}

---
GOAL (GOAL.md):
$(cat GOAL.md)

---
CURRENT FEEDBACK (COMMENTs.md):
$(cat COMMENTs.md)"
  fi

  if $DRY_RUN; then
    log "  [DRY-RUN] Would run: $WORKER_TOOL $WORKER_FLAGS '<prompt>'"
  else
    read -ra _WFLAGS <<< "$WORKER_FLAGS"
    $WORKER_TOOL "${_WFLAGS[@]}" "$FULL_WORKER_PROMPT" \
      || { log "Worker exited non-zero — continuing anyway"; }
  fi

  # ── SCORE step ────────────────────────────────────────────────────────────
  log "Scoring..."
  prev_score=$score
  score=0
  score_json="{}"
  if ! $DRY_RUN; then
    score=$(bash score.sh 2>/dev/null) || score=0
    score_json=$(bash score.sh --json 2>/dev/null) || score_json="{}"
  fi
  log "Score: $score / 100 (best so far: $best_score)"

  # ── Persist state to STATE.sh ────────────────────────────────────────────
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  TOTAL_ITERATIONS=$(( TOTAL_ITERATIONS + 1 ))
  cat > "$STATE_FILE" << STATEOF
HEPH_STATE_VERSION=1
HEPH_TOTAL_ITERATIONS=${TOTAL_ITERATIONS}
HEPH_BEST_SCORE=${best_score}
HEPH_CURRENT_SCORE=${score}
HEPH_NO_IMPROVE_COUNT=${no_improve_count}
HEPH_LAST_SESSION_TS="${SESSION_TS}"
HEPH_LAST_ITER_TS="${ts}"
HEPH_STATUS="RUNNING"
STATEOF

  # ── Check stopping condition: target reached ──────────────────────────────
  if (( score >= TARGET_SCORE )); then
    notify "Target ${TARGET_SCORE} reached! Final score: ${score}. Done in ${iter} iterations."
    exit_code=0
    break
  fi

  # ── Commit or revert ──────────────────────────────────────────────────────
  kept=false
  delta=$(( score - best_score ))

  if (( score > best_score )); then
    best_score=$score
    no_improve_count=0
    kept=true
    if [ "$(_cfg git.commit_on_improvement true)" = "True" ] || \
       [ "$(_cfg git.commit_on_improvement true)" = "true" ]; then
      run "git add -A && git commit -m '[S:${prev_score}→${score}] iter ${iter}: score improved' --allow-empty" \
        || log "git commit skipped (not a repo or nothing staged)"
    fi
    log "Improvement! Committed. (delta: +$delta)"
  else
    no_improve_count=$(( no_improve_count + 1 ))
    log "No improvement (delta: $delta). No-improve streak: $no_improve_count/$NO_IMPROVE_LIMIT"
    if [ "$REVERT_ON_REGRESSION" = "true" ] && (( score < best_score )); then
      run "git checkout -- . 2>/dev/null" || log "Revert skipped (not a repo)"
      log "Regression detected — reverted changes."
    fi
  fi

  # ── Log iteration ─────────────────────────────────────────────────────────
  action_summary=$(head -10 SUMMARY.md 2>/dev/null | tr '\n' ' ' || echo "no summary")
  action_summary="${action_summary//\"/\\\"}"
  result_str="reverted"
  $kept && result_str="kept"
  echo "{\"iteration\":$iter,\"before\":$prev_score,\"after\":$score,\"best\":$best_score,\"delta\":$delta,\"result\":\"$result_str\",\"scores\":$score_json,\"action\":\"${action_summary}\",\"ts\":\"$ts\",\"session\":\"${SESSION_TS}\"}" \
    >> "$LOG_DIR/iterations.jsonl"
  if [ -f SUMMARY.md ]; then
    cp SUMMARY.md "$LOG_DIR/iter-${iter}-summary.md" 2>/dev/null || true
  fi

  # ── Check stopping condition: plateau ────────────────────────────────────
  if (( no_improve_count >= NO_IMPROVE_LIMIT )); then
    notify "Plateau after $iter iterations (${NO_IMPROVE_LIMIT} with no improvement). Best: ${best_score}/100."
    exit_code=1
    break
  fi

  # ── REVIEWER step ─────────────────────────────────────────────────────────
  log "Reviewer ($REVIEWER_TOOL) starting..."
  REVIEWER_PROMPT="$(echo "$REVIEWER_ROLE" \
    | sed "s|{SCORE}|${score}|g; s|{TARGET}|${TARGET_SCORE}|g")

WORKFLOW DECISIONS (authoritative):
$(cat "$DECISIONS_FILE" 2>/dev/null || echo '(none)')

WORKFLOW MEMORY:
$(cat "$MEMORY_FILE" 2>/dev/null || echo '(no memory)')

GOAL.md contents:
$(cat GOAL.md)

SUMMARY.md contents:
$(cat SUMMARY.md 2>/dev/null || echo '(empty — worker has not written yet)')

Write your feedback to COMMENTs.md. Be specific: name files, line numbers, and exact actions.
Include a clear 'Next Priority Action' line for the Worker."

  if $DRY_RUN; then
    log "  [DRY-RUN] Would run: $REVIEWER_TOOL $REVIEWER_FLAGS '<prompt>' > COMMENTs.md"
  else
    read -ra _RFLAGS <<< "$REVIEWER_FLAGS"
    $REVIEWER_TOOL "${_RFLAGS[@]}" "$REVIEWER_PROMPT" > COMMENTs.md \
      || { log "Reviewer exited non-zero — continuing anyway"; }
  fi

  log "Reviewer wrote COMMENTs.md ($(wc -l < COMMENTs.md) lines)"

  # ── Update workflow memory ─────────────────────────────────────────────────
  update_memory
done

# ── Final summary ─────────────────────────────────────────────────────────────
if (( iter >= MAX_ITER )) && (( exit_code != 0 )); then
  notify "Max iterations ($MAX_ITER) reached. Best score: ${best_score}/100."
  exit_code=2
fi

if [ -f "$STATE_FILE" ]; then
  case $exit_code in
    0) status="COMPLETE" ;;
    1) status="PLATEAU" ;;
    2) status="TIMEOUT" ;;
    *) status="UNKNOWN" ;;
  esac
  sed -i "s/^HEPH_STATUS=.*/HEPH_STATUS=\"${status}\"/" "$STATE_FILE"
fi

log "━━━ Loop complete ━━━"
log "Project      : $PROJECT_NAME"
log "Iterations   : $iter"
log "Best score   : $best_score / 100"
log "Exit code    : $exit_code (0=success 1=plateau 2=timeout 3=test-break)"
log "Logs         : $LOG_DIR"

exit $exit_code
