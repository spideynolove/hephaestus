# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

An automated **Worker↔Reviewer loop** framework. `orchestrate.sh` runs two AI agents in alternation:
- **Worker** (`codex exec --full-auto`): reads `GOAL.md` + `COMMENTs.md`, applies code changes, writes `SUMMARY.md`
- **Reviewer** (`claude --print`): reads `SUMMARY.md` + `GOAL.md`, writes targeted feedback to `COMMENTs.md`

The loop runs until score ≥ target, plateau is detected, or max iterations is reached.

## Running the Loop

```bash
cp .env.example .env          # add ANTHROPIC_API_KEY and OPENAI_API_KEY
./orchestrate.sh              # run with config.yaml defaults
./orchestrate.sh --max-iter 5 # override max iterations
./orchestrate.sh --target 80  # override target score
./orchestrate.sh --dry-run    # print commands without executing
```

Prerequisites: `python3`, `pyyaml` (`pip install pyyaml`), `codex` and `claude` on PATH.

## Scoring

`score.sh` outputs a single integer 0–100. Run it directly to see the breakdown:

```bash
bash score.sh          # stdout: score integer; stderr: breakdown details
```

Current weights (edit `config.yaml` to change):
- Tests passing: 40 pts (npm test or pytest)
- Lint warnings: 30 pts (eslint or ruff)
- Code coverage: 30 pts (jest --coverage or pytest-cov)

## Key Files

| File | Purpose |
|------|---------|
| `GOAL.md` | Task objective, constraints, action catalog — **edit this per project** |
| `config.yaml` | Agent commands, loop control, scoring weights |
| `COMMENTs.md` | Reviewer feedback → Worker input (rewritten each iteration) |
| `SUMMARY.md` | Worker progress report → Reviewer input (created by worker) |
| `logs/iterations.jsonl` | Per-iteration score history |
| `.env` | API keys (not committed) |

## Adapting to a New Project

1. Edit `GOAL.md` — replace the template with your actual objective and constraints
2. Edit `score.sh` — implement scoring logic matching your project's test/lint/coverage tools
3. Edit `config.yaml` — adjust `agents.worker.tool`, `agents.reviewer.tool`, weights, and limits
4. Set `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` in `.env`

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Score ≥ target reached |
| 1 | Plateau (N consecutive iterations with no improvement) |
| 2 | Max iterations reached |
| 3 | Tests broken after change (immediate revert) |

## Loop Behavior

- On improvement: commits changes with message `ai-loop iter N: score S` (if `git.commit_on_improvement: true`)
- On regression: reverts via `git checkout -- .` (if `revert_on_regression: true`)
- Optional Slack notifications via `SLACK_WEBHOOK_URL`
