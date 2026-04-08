#!/usr/bin/env bash
set -euo pipefail

# Guard: prevent recursive scoring (e.g. score.sh called from within bats tests)
if [ -n "${HEPHAESTUS_SCORING:-}" ]; then
  echo "0"
  exit 0
fi
export HEPHAESTUS_SCORING=1

SCORE=0
SHELLCHECK_SCORE=0
TESTS_SCORE=0
DOCS_SCORE=0
DETAILS=""

# ── Component 1: Shellcheck (30 pts) ──────────────────────────────────────────
if command -v shellcheck &>/dev/null; then
  RAW=$(shellcheck -x orchestrate.sh score.sh setup.sh 2>&1 || true)
  ERRORS=$(echo "$RAW"   | grep -c ' (error)'   || true)
  WARNINGS=$(echo "$RAW" | grep -c ' (warning)' || true)
  ISSUES=$(( ERRORS * 2 + WARNINGS ))
  SHELLCHECK_SCORE=$(( 30 - ISSUES * 3 ))
  [ "$SHELLCHECK_SCORE" -lt 0 ] && SHELLCHECK_SCORE=0
  DETAILS="${DETAILS}shellcheck: ${ERRORS} errors, ${WARNINGS} warnings (+${SHELLCHECK_SCORE})\n"
else
  DETAILS="${DETAILS}shellcheck: not installed (+0)\n"
fi
SCORE=$(( SCORE + SHELLCHECK_SCORE ))

# ── Component 2: Bats tests (40 pts) ──────────────────────────────────────────
if command -v bats &>/dev/null && [ -d tests ] && ls tests/*.bats &>/dev/null 2>&1 && [ -z "${HEPHAESTUS_SCORING_INNER:-}" ]; then
  BATS_OUT=$(HEPHAESTUS_SCORING_INNER=1 bats tests/*.bats 2>&1 || true)
  PASS=$(echo "$BATS_OUT" | grep -c '^ok '     || true)
  FAIL=$(echo "$BATS_OUT" | grep -c '^not ok ' || true)
  TOTAL=$(( PASS + FAIL ))
  if [ "$TOTAL" -gt 0 ]; then
    if [ "$FAIL" -eq 0 ]; then
      TESTS_SCORE=40
    else
      TESTS_SCORE=$(( 40 * PASS / TOTAL ))
    fi
  fi
  DETAILS="${DETAILS}tests: ${PASS}/${TOTAL} passed (+${TESTS_SCORE})\n"
else
  DETAILS="${DETAILS}tests: no tests/*.bats found (+0)\n"
fi
SCORE=$(( SCORE + TESTS_SCORE ))

# ── Component 3: Documentation (30 pts) ───────────────────────────────────────
for section in "Fitness Function" "Operating Mode" "Improvement Loop" "Action Catalog" "Constraints"; do
  grep -q "^## ${section}" GOAL.md 2>/dev/null && DOCS_SCORE=$(( DOCS_SCORE + 4 ))
done
for section in "Installation" "Usage" "Logs" "Scoring" "How the Loop Works"; do
  grep -q "^## ${section}" README.md 2>/dev/null && DOCS_SCORE=$(( DOCS_SCORE + 2 ))
done
[ "$DOCS_SCORE" -gt 30 ] && DOCS_SCORE=30
DETAILS="${DETAILS}docs: (+${DOCS_SCORE})\n"
SCORE=$(( SCORE + DOCS_SCORE ))

# ── Output ─────────────────────────────────────────────────────────────────────
echo -e "Score breakdown:\n${DETAILS}Total: ${SCORE}/100" >&2
if [[ "${1:-}" == "--json" ]]; then
  echo "{\"score\":$SCORE,\"shellcheck\":$SHELLCHECK_SCORE,\"tests\":$TESTS_SCORE,\"docs\":$DOCS_SCORE}"
else
  echo "$SCORE"
fi
