#!/usr/bin/env bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  cd "$REPO_ROOT"
  unset HEPHAESTUS_RUNNING
  unset HEPHAESTUS_SCORING
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

@test "orchestrate.sh --dry-run creates STATE.sh" {
  run bash orchestrate.sh --dry-run --max-iter 1
  [ -f STATE.sh ]
}

@test "STATE.sh contains HEPH_STATE_VERSION" {
  run bash orchestrate.sh --dry-run --max-iter 1
  [ -f STATE.sh ]
  grep -q 'HEPH_STATE_VERSION=1' STATE.sh
}

@test "STATE.sh contains HEPH_BEST_SCORE" {
  run bash orchestrate.sh --dry-run --max-iter 1
  grep -q 'HEPH_BEST_SCORE=' STATE.sh
}

@test "orchestrate.sh --dry-run creates MEMORY.md" {
  run bash orchestrate.sh --dry-run --max-iter 1
  [ -f MEMORY.md ]
}

@test "MEMORY.md contains Workflow Memory header" {
  run bash orchestrate.sh --dry-run --max-iter 1
  grep -q '# Workflow Memory' MEMORY.md
}

@test "MEMORY.md contains Current State section" {
  run bash orchestrate.sh --dry-run --max-iter 1
  grep -q '## Current State' MEMORY.md
}

@test "MEMORY.md contains Score Trajectory section" {
  run bash orchestrate.sh --dry-run --max-iter 1
  grep -q '## Score Trajectory' MEMORY.md
}

@test "MEMORY.md contains Next Priority Actions section" {
  run bash orchestrate.sh --dry-run --max-iter 1
  grep -q '## Next Priority Actions' MEMORY.md
}

@test "orchestrate.sh --dry-run creates DECISIONS.md" {
  run bash orchestrate.sh --dry-run --max-iter 1
  [ -f DECISIONS.md ]
}

@test "DECISIONS.md contains authoritative directive" {
  run bash orchestrate.sh --dry-run --max-iter 1
  grep -q 'authoritative' DECISIONS.md
}

@test "DECISIONS.md is not overwritten on second run" {
  run bash orchestrate.sh --dry-run --max-iter 1
  [ -f DECISIONS.md ]
  BEFORE=$(md5sum DECISIONS.md | cut -d' ' -f1)
  run bash orchestrate.sh --dry-run --max-iter 1
  AFTER=$(md5sum DECISIONS.md | cut -d' ' -f1)
  [ "$BEFORE" = "$AFTER" ]
}

@test "corrupted STATE.sh triggers warning" {
  echo "GARBAGE" > STATE.sh
  run bash orchestrate.sh --dry-run --max-iter 1
  [[ "$output" == *"WARNING"* ]]
}

@test "MEMORY.md respects max line cap" {
  run bash orchestrate.sh --dry-run --max-iter 1
  lines=$(wc -l < MEMORY.md)
  [ "$lines" -le 80 ]
}

@test "memory injection appears in dry-run worker output" {
  run bash orchestrate.sh --dry-run --max-iter 1
  [[ "$output" == *"WORKFLOW MEMORY"* ]] || [[ "$output" == *"Would run"* ]]
}
