#!/usr/bin/env bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  cd "$REPO_ROOT"
  unset HEPHAESTUS_SCORING
}

@test "score.sh passes bash syntax check" {
  run bash -n score.sh
  [ "$status" -eq 0 ]
}

@test "score.sh outputs a single integer to stdout" {
  result=$(bash score.sh 2>/dev/null)
  [[ "$result" =~ ^[0-9]+$ ]]
}

@test "score.sh integer is between 0 and 100" {
  result=$(bash score.sh 2>/dev/null)
  [ "$result" -ge 0 ]
  [ "$result" -le 100 ]
}

@test "score.sh --json outputs valid JSON" {
  result=$(bash score.sh --json 2>/dev/null)
  [[ "$result" == "{"* ]]
  [[ "$result" == *"}" ]]
}

@test "score.sh --json contains score key" {
  run bash score.sh --json 2>/dev/null
  [[ "$output" == *'"score"'* ]]
}

@test "score.sh --json score value is an integer" {
  score_val=$(bash score.sh --json 2>/dev/null | grep -o '"score":[0-9]*' | grep -o '[0-9]*$')
  [[ "$score_val" =~ ^[0-9]+$ ]]
}

@test "score.sh --json contains correctness key" {
  run bash score.sh --json 2>/dev/null
  [[ "$output" == *'"correctness"'* ]]
}

@test "score.sh writes breakdown to stderr not stdout" {
  stdout=$(bash score.sh 2>/dev/null)
  [[ "$stdout" =~ ^[0-9]+$ ]]
}
