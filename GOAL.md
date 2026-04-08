# Goal: Make hephaestus robust and well-tested

## Fitness Function

```bash
bash score.sh          # human-readable breakdown to stderr, integer to stdout
bash score.sh --json   # {"score":N,"shellcheck":N,"tests":N,"docs":N}
```

### Metric Definition

```
score = shellcheck_score + tests_score + docs_score
```

| Component | Max | What it measures | How |
|-----------|-----|------------------|-----|
| **Shellcheck** | 30 | Zero warnings/errors across all `.sh` files | `shellcheck -x orchestrate.sh score.sh setup.sh` |
| **Tests** | 40 | Bats test suite passes | `bats tests/` |
| **Docs** | 30 | GOAL.md + README have all required sections | grep checks |

### Metric Mutability

- [x] **Open** — Agent may improve scripts, add tests, fix docs, and update score.sh if the metric itself is wrong

## Operating Mode

- [x] **Converge** — Stop when criteria met

### Stopping Conditions

- `score >= 95`
- 5 consecutive iterations with no improvement
- 20 iterations completed
- Any required file (`orchestrate.sh`, `score.sh`, `setup.sh`) deleted

## Bootstrap

1. `sudo apt install shellcheck bats` — required for scoring
2. `bash score.sh` — record baseline (expect ~38/100)
3. `./orchestrate.sh` — run the loop

## Improvement Loop

```
repeat:
  0. Read logs/hephaestus/iterations.jsonl — note what has been tried
  1. bash score.sh --json > /tmp/before.json
  2. Read component breakdown — find weakest
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
| Create `tests/` and write bats tests for `orchestrate.sh --dry-run` | +15 pts | `mkdir tests && cat > tests/orchestrate.bats` — test dry-run exits 0, logs created |
| Write bats tests for `score.sh --json` output | +10 pts | Assert JSON contains `score` key, integer value |
| Write bats tests for `setup.sh` syntax and behavior | +10 pts | Test `bash -n setup.sh` passes, required prompts exist |
| Fix SC2144 glob error in `score.sh` (lines 47-48) | +8 pts | Replace `-f .eslintrc*` glob with a `for` loop or `ls` check |
| Fix SC2086 unquoted `$WORKER_FLAGS` / `$REVIEWER_FLAGS` in `orchestrate.sh` | +5 pts | Add double quotes |
| Fix SC2163 `export "$line"` bug in `setup.sh` | +5 pts | Use `export "${line?}"` or split key/value |
| Fix SC2034 unused variables (`score_details`, `PROJECT_NAME`) | +3 pts | Remove or use them |
| Fix SC2001 sed→bash substitution style in `orchestrate.sh` | +2 pts | Use `${var//search/replace}` |
| Add missing README sections if any | +2 pts | Check grep against required headings |

## Constraints

1. **Never delete `orchestrate.sh`, `score.sh`, or `setup.sh`**
2. **Never use `# shellcheck disable` comments** — fix the root cause
3. **Never fabricate test results** — bats must actually run the tests
4. **Never break `./orchestrate.sh --dry-run`** — verify after each change

## File Map

| File | Role | Editable? |
|------|------|-----------|
| `orchestrate.sh` | Loop runner | Yes |
| `score.sh` | Fitness function | Yes |
| `setup.sh` | Setup wizard | Yes |
| `GOAL.md` | This file | Yes |
| `README.md` | Documentation | Yes |
| `config.yaml` | Loop config | Yes |
| `tests/*.bats` | Bats test suite | Yes — create these |
| `logs/hephaestus/iterations.jsonl` | Iteration history | Append only |
| `.env` | Active config | No |

## When to Stop

```
Starting score: 49 / 100
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
