# Goal: Make hephaestus effective at improving projects

## Fitness Function

```bash
bash score.sh          # human-readable breakdown to stderr, integer to stdout
bash score.sh --json   # {"score":N,"correctness":N}
```

### Metric Definition

```
score = correctness (0–100, based on bats test pass rate)
```

| Component | Max | What it measures | How |
|-----------|-----|------------------|-----|
| **Correctness** | 100 | All bats tests pass: memory mechanism, state persistence, prompt injection | `bats tests/*.bats` |

### Metric Mutability

- [x] **Open** — Agent may improve scripts, add tests, fix mechanisms, and update score.sh if the metric itself is wrong

## Operating Mode

- [x] **Converge** — Stop when criteria met

### Stopping Conditions

- `score >= 95`
- 5 consecutive iterations with no improvement
- 20 iterations completed
- Any required file (`orchestrate.sh`, `score.sh`, `setup.sh`) deleted

## Bootstrap

1. `sudo apt install shellcheck bats` — required for scoring
2. `bash score.sh` — record baseline
3. `./orchestrate.sh` — run the loop

## Improvement Loop

```
repeat:
  0. Read logs/hephaestus/iterations.jsonl — note what has been tried
  1. bash score.sh --json > /tmp/before.json
  2. Read component breakdown — find failing tests
  3. Pick highest-impact action from Action Catalog
  4. Make the change
  5. bash score.sh --json > /tmp/after.json
  6. If score improved: commit with [S:NN→NN] format
  7. If unchanged/regressed: revert
  8. Append to iterations.jsonl
```

Commit format: `[S:NN→NN] component: what changed`

## Action Catalog

| Action | Impact | How |
|--------|--------|-----|
| Fix failing orchestrate.bats tests | +pts per test | Run `bats tests/orchestrate.bats`, fix each failure |
| Fix failing score.bats tests | +pts per test | Run `bats tests/score.bats`, fix each failure |
| Fix failing setup.bats tests | +pts per test | Run `bats tests/setup.bats`, fix each failure |
| Add missing correctness tests for memory mechanism | +pts | Test STATE.sh restore, MEMORY.md cap, condensation, edge cases |
| Fix shellcheck warnings | +maintainability | `shellcheck -x orchestrate.sh score.sh setup.sh` |

## Constraints

1. **Never delete `orchestrate.sh`, `score.sh`, or `setup.sh`**
2. **Never use `# shellcheck disable` comments** — fix the root cause
3. **Never fabricate test results** — bats must actually run the tests
4. **Never break `./orchestrate.sh --dry-run`** — verify after each change

## File Map

| File | Role | Editable? |
|------|------|-----------|
| `orchestrate.sh` | Loop runner with memory mechanism | Yes |
| `score.sh` | Fitness function (correctness tests) | Yes |
| `setup.sh` | Setup wizard | Yes |
| `GOAL.md` | This file | Yes |
| `README.md` | Documentation | Yes |
| `config.yaml` | Loop config | Yes |
| `MEMORY.md` | Workflow memory (auto-generated) | No — managed by loop |
| `STATE.sh` | Machine-readable state (auto-generated) | No — managed by loop |
| `DECISIONS.md` | Anti-deviation anchor (auto-generated) | No — managed by loop |
| `tests/*.bats` | Bats test suite | Yes — create/edit these |
| `logs/hephaestus/iterations.jsonl` | Iteration history | Append only |
| `.env` | Active config | No |

## When to Stop

```
Starting score: NN / 100
Ending score:   NN / 100
Iterations:     N
Exit reason:    target reached / plateau / timeout
Changes made:
  - (list each file changed and what was fixed)
Remaining gaps:
  - (what would still need work to reach 100)
Next actions:
  - (what a human should review or extend)
```
