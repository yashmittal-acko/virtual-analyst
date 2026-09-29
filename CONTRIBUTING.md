# Contributing to Virtual Analyst

## The rule: never edit SKILL.md directly in GitHub

All changes to pod files go through **Pod Builder** — a Claude conversation. Pod Builder writes the files, opens the PR, and routes it for approval. You should not need to touch GitHub at all for day-to-day analyst work.

If you're a platform engineer editing shared infrastructure (`shared/`, `registry/`, `access/`, `build/`, `.github/`), proceed directly.

---

## What changes what

| I want to... | How |
|---|---|
| Fix a metric definition | Open Pod Builder → describe the fix → confirm the diff → Pod Builder opens the PR |
| Add a new SQL pattern | Open Pod Builder → paste the analysis/RCA you ran → Pod Builder extracts the pattern |
| Capture a correct answer as an eval | Reply ✓ in Claude → Pod Builder auto-captures and opens a PR |
| Change the guardrails | Edit `shared/GUARDRAILS.md` → run `python3 build/inject_guardrails.py` → commit all 6 SKILL.md files → PR |
| Add a new pod | See **Adding a new pod** below |
| Promote a pod to prod | Run `python3 build/promote.py --pod <name>` — it checks everything before tagging |

---

## CI gates on every PR

A PR touching any pod file must pass all three workflows before it can merge:

**guardrails-ci.yml** — checks the guardrail hash is current in every SKILL.md. Fails if someone edited the guardrail block directly inside a SKILL.md without re-running the inject script.

**evals-ci.yml** — runs all `status: confirmed` evals against BigQuery and checks results within `tolerance_pct`. Fails if any number regresses.

**guardrails-ci.yml (PII + SQL scan)** — scans `patterns.sql` for raw phone/email columns and `SELECT *`.

All three must be green. CODEOWNERS enforces that the pod owner approves changes to their own pod files.

---

## Bumping a pod version

Every change that goes to prod requires a VERSION bump:

```
# Before opening the PR, bump the pod's version:
echo "1.0.1" > skills/adsc/VERSION
git add skills/adsc/VERSION
```

`promote.py` will block if VERSION hasn't changed since the last git tag.

Versioning convention: `MAJOR.MINOR.PATCH`
- PATCH: metric description fix, eval correction, pattern clarification
- MINOR: new metric, new SQL pattern, new eval
- MAJOR: table swap, schema breaking change, analyst change

---

## Adding a new pod

1. Create the directory structure:
```bash
mkdir -p skills/<pod_id>/{semantic,analyses,evals}
```

2. Create the 4 files: `SKILL.md`, `semantic/metrics.csv`, `analyses/patterns.sql`, `evals/metric_evals.yaml`

3. Add a VERSION file: `echo "1.0.0" > skills/<pod_id>/VERSION`

4. Run guardrail injection: `python3 build/inject_guardrails.py --pod <pod_id>`

5. Add the pod to `registry/router.yaml` with trigger terms and exclusions.

6. Add the pod to `access/pods.yaml` with dataset grants and PII controls.

7. Add the pod owner to `.github/CODEOWNERS`.

8. Open a PR. Platform owner reviews and merges.

---

## Schema corrections

If a query reveals a wrong column name (happens when metrics.csv is written before confirming against BigQuery):

1. Fix `semantic/metrics.csv` with the correct column name.
2. Fix `analyses/patterns.sql` if the pattern used the wrong column.
3. Update the relevant eval's `sql` note in `evals/metric_evals.yaml`.
4. Run `python3 build/validate_schema.py --pod <pod_id>` to confirm.
5. Bump VERSION (PATCH), open PR.

---

## Eval runner

To run evals locally before opening a PR:

```bash
# Install deps
pip install google-cloud-bigquery pyyaml

# Authenticate
gcloud auth application-default login

# Run all evals
python3 build/run_evals.py

# Run one pod
python3 build/run_evals.py --pod adsc

# Dry-run (prints queries without running)
python3 build/run_evals.py --dry-run
```
