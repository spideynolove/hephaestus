#!/usr/bin/env bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  cd "$REPO_ROOT"
  unset HEPHAESTUS_RUNNING
  unset HEPHAESTUS_SCORING
}

@test "setup.sh passes bash syntax check" {
  run bash -n setup.sh
  [ "$status" -eq 0 ]
}

@test "setup.sh file exists and is readable" {
  [ -f setup.sh ]
  [ -r setup.sh ]
}

@test "setup.sh contains Step 0" {
  grep -q "Step 0" setup.sh
}

@test "setup.sh contains Step 1" {
  grep -q "Step 1" setup.sh
}

@test "setup.sh contains required ask prompts" {
  grep -q "ask.*PROJECT_PATH" setup.sh
}

@test "setup.sh contains provider choices" {
  grep -q "OAuth" setup.sh
  grep -q "OpenRouter" setup.sh
}
