# Iteration 0 — Initial Feedback

Current score: 49/100
- shellcheck: 21/30 (3 warnings remain)
- tests: 0/40 (no tests/ directory yet)
- docs: 28/30

## Highest-impact action: create bats tests (+40 pts)

Create `tests/orchestrate.bats`, `tests/score.bats`, and `tests/setup.bats`.

Example test structure for `tests/orchestrate.bats`:
```bash
#!/usr/bin/env bats

@test "orchestrate.sh has valid syntax" {
  run bash -n orchestrate.sh
  [ "$status" -eq 0 ]
}

@test "orchestrate.sh --dry-run exits 0" {
  run bash orchestrate.sh --dry-run --max-iter 1
  [ "$status" -eq 0 ]
}

@test "orchestrate.sh rejects unknown arguments" {
  run bash orchestrate.sh --unknown-flag
  [ "$status" -eq 1 ]
}
```

Example for `tests/score.bats`:
```bash
@test "score.sh produces integer output" {
  run bash score.sh
  [[ "$output" =~ ^[0-9]+$ ]]
}

@test "score.sh --json produces valid JSON with score key" {
  run bash score.sh --json
  [[ "$output" == *'"score"'* ]]
}
```

After creating tests, fix the 3 shellcheck warnings to push shellcheck from 21→30.
Run `bash score.sh` to verify score improves before writing SUMMARY.md.
