#!/usr/bin/env bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  cd "$REPO_ROOT"
  unset HEPHAESTUS_RUNNING
}

@test "orchestrate.sh passes bash syntax check" {
  run bash -n orchestrate.sh
  [ "$status" -eq 0 ]
}

@test "orchestrate.sh --dry-run exits with a known exit code (0=success 1=plateau 2=timeout)" {
  run bash orchestrate.sh --dry-run
  [ "$status" -le 2 ]
}

@test "orchestrate.sh --dry-run prints DRY-RUN marker" {
  run bash orchestrate.sh --dry-run
  [[ "$output" == *"[DRY-RUN]"* ]]
}

@test "orchestrate.sh --dry-run prints loop started message" {
  run bash orchestrate.sh --dry-run
  [[ "$output" == *"Starting loop"* ]]
}

@test "orchestrate.sh rejects unknown arguments" {
  run bash orchestrate.sh --unknown-flag
  [ "$status" -ne 0 ]
}

@test "orchestrate.sh --max-iter 1 --dry-run completes" {
  run bash orchestrate.sh --dry-run --max-iter 1
  [ "$status" -le 2 ]
}

@test "orchestrate.sh --target 50 --dry-run completes" {
  run bash orchestrate.sh --dry-run --target 50
  [ "$status" -le 2 ]
}

@test "orchestrate.sh --dry-run creates logs directory" {
  run bash orchestrate.sh --dry-run
  [ -d logs ]
}
