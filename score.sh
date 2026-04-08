#!/usr/bin/env bash
set -euo pipefail

if [ -n "${HEPHAESTUS_SCORING:-}" ]; then
  echo "0"
  exit 0
fi
export HEPHAESTUS_SCORING=1

SCORE=0
CORRECTNESS_SCORE=0
DETAILS=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if command -v bats &>/dev/null && [ -d tests ] && compgen -G 'tests/*.bats' >/dev/null 2>&1 && [ -z "${HEPHAESTUS_SCORING_INNER:-}" ]; then
  BATS_OUT=$(HEPHAESTUS_SCORING_INNER=1 bats tests/*.bats 2>&1 || true)
  PASS=$(echo "$BATS_OUT" | grep -c '^ok '     || true)
  FAIL=$(echo "$BATS_OUT" | grep -c '^not ok ' || true)
  TOTAL=$(( PASS + FAIL ))
  if [ "$TOTAL" -gt 0 ]; then
    if [ "$FAIL" -eq 0 ]; then
      CORRECTNESS_SCORE=100
    else
      CORRECTNESS_SCORE=$(( 100 * PASS / TOTAL ))
    fi
  fi
  DETAILS="${DETAILS}correctness: ${PASS}/${TOTAL} tests passed (+${CORRECTNESS_SCORE})\n"
else
  DETAILS="${DETAILS}correctness: no tests found (+0)\n"
fi
SCORE=$CORRECTNESS_SCORE

echo -e "Score breakdown:\n${DETAILS}Total: ${SCORE}/100" >&2
if [[ "${1:-}" == "--json" ]]; then
  echo "{\"score\":$SCORE,\"correctness\":$CORRECTNESS_SCORE}"
else
  echo "$SCORE"
fi
