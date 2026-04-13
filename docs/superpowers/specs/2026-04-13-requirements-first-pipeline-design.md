# Requirements-First Pipeline Design

**Date:** 2026-04-13
**Status:** Approved for implementation

---

## Problem

The current `goal-init.sh` derives its fitness function from the existing codebase.
This produces circular validation: the generated `score.sh` measures whether the code
does what it already does, so any sufficiently complete project scores 100/100 before
any improvement work begins.

Three root causes:
1. No user-intent source of truth exists before code analysis runs
2. `score.sh` defaults to linter/coverage proxies rather than functional probes
3. The Reviewer writes generic feedback not anchored to specific requirements

---

## Design

### New pipeline order

```
req-init.sh   →   goal-init.sh   →   setup.sh   →   orchestrate.sh
```

`req-init.sh` is a new tool. `goal-init.sh`, `orchestrate.sh`, and the Reviewer
prompt are refactored. `setup.sh` is unchanged.

---

### 1. `req-init.sh` — new tool

**Purpose:** Convert a raw idea into a validated `REQUIREMENTS.md`.

**Usage:**
```bash
req-init.sh <project-path> [--idea "raw text" | --idea-file path]
```

**Behavior:**
- Loads `req-system-prompt.md` from the hephaestus repo (user-editable)
- Calls the AI with the raw idea + system prompt
- AI runs a structured 3-phase interview via the REST API (same `ai_run_prompt`
  function as `goal-init.sh`):
  - Phase 1: Purpose extraction — what problem, what failure looks like
  - Phase 2: Requirement elicitation — one capability at a time, observable outcome,
    testability check, priority classification
  - Phase 3: Completeness check — reviews draft back to user, asks what's missing
- Writes `REQUIREMENTS.md` to `<project-path>/`
- User reviews and edits before proceeding
- Validates schema before exiting (every REQ has Intent + Acceptance + Priority)

**`req-system-prompt.md`** ships with hephaestus, is version-controlled, and is the
user's primary lever for tuning how requirements are extracted.

---

### 2. `REQUIREMENTS.md` schema

```markdown
# Requirements: <project name>
<!-- req-version: 1 -->

## REQ-001: <short title>
**Intent:** User outcome, not implementation detail.
**Acceptance:** Single observable, shell-testable condition. "Running X produces Y."
**Priority:** must | should | nice-to-have
**Probe hint:** (optional) concrete command + expected output

## REQ-002: ...
```

**Rules:**
- Each REQ covers exactly one testable condition (no "and" in Acceptance)
- Intent describes user outcome, never implementation
- Acceptance must be verifiable by a shell script without human judgment
- `score.sh` section keys are machine-derived: `REQ-001` → `req_001`

---

### 3. `goal-init.sh` — refactored

**Phase 0 — Preflight:**
- Require `REQUIREMENTS.md` exists; exit with instructions if missing
- Validate schema: every REQ has Intent + Acceptance + Priority

**Phase 1 — Gap analysis** (replaces current "First Principles analysis"):
- repomix packs the codebase (unchanged)
- For each REQ, AI determines current status: `passing` / `failing` / `unknown`
- Presents gap table to user for review and correction

**Phase 2 — Generate `score.sh`:**
- One bash function per REQ, keyed `req_001`, `req_002`, etc.
- Function implements the Acceptance criterion as a behavioral probe
- Uses Probe hint if provided; AI derives probe if not
- `passing` REQs start at full points (regression detection)
- `failing` REQs start at 0 (improvement target)
- No linter/coverage sections unless a REQ explicitly requires them

**Phase 3 — Generate `GOAL.md`:**
- Action catalog: one entry per `failing` REQ only
- Each entry: file/line target, concrete fix, validation command
- Stopping condition: all REQs passing for 3 consecutive runs

---

### 4. `score.sh` contract

- Exactly one scored section per REQ-ID — nothing else
- Each section runs a real behavioral probe (not `ruff`, not `pytest --cov` by default)
- `--json` output keys match REQ-IDs: `{"score": 80, "req_001": 20, "req_002": 0, ...}`
- Probe failures are silent to stdout; score is 0 for that section

---

### 5. Reviewer prompt — refactored

The Reviewer receives: `REQUIREMENTS.md` + `score.sh --json` output + `SUMMARY.md`.
It does not receive raw code.

Output written to `COMMENTs.md`:

```markdown
# Reviewer Feedback — Iteration N

## Score: X/100

| REQ | Title | Score | Status |
|-----|-------|-------|--------|
| REQ-001 | ... | 20/20 | ✓ passing |
| REQ-002 | ... | 0/20  | ✗ failing |
| REQ-003 | ... | 10/20 | ⚠ partial |

## Next Priority Action
**REQ-002** — <exact action from GOAL.md action catalog>

## Do Not Attempt
- REQ-001: already passing — do not touch

## Observations
- <what the Worker changed this iteration>
- <whether it moved the score for its target REQ>
- <any probe that seems to be measuring the wrong thing>
```

---

### 6. `orchestrate.sh` — changes

- Passes `REQUIREMENTS.md` to Reviewer context (alongside `SUMMARY.md` + score output)
- Passes `REQUIREMENTS.md` to Worker context (alongside `GOAL.md` + `COMMENTs.md`)
- Warns if `REQUIREMENTS.md` is newer than `score.sh` (requirements changed, score.sh stale)

---

## Files added / changed

| File | Change |
|------|--------|
| `req-init.sh` | New |
| `req-system-prompt.md` | New — user-editable AI interview guide |
| `goal-init.sh` | Refactored — reads REQUIREMENTS.md, phase 1 is gap analysis |
| `orchestrate.sh` | Modified — passes REQUIREMENTS.md to Worker + Reviewer |
| `setup.sh` | Unchanged |

---

## What does not change

- `setup.sh` — provider/model/engine selection unchanged
- `ai_run_prompt` function — reused in `req-init.sh`
- repomix integration — still used in `goal-init.sh` phase 1 for gap analysis
- score.sh verification at end of `goal-init.sh` — unchanged
