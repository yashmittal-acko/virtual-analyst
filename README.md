# Virtual Analyst — Pod Repository

Governed mono-repo for Acko's Virtual Analyst platform. Each pod is one business-line analyst powered by Claude, with a canonical metric layer, approved SQL patterns, and CI-gated evals.

## Pods

| Pod ID | Skill Name | Role | Owner |
|---|---|---|---|
| adsc | AVA | ADSC (Acko Drive Service Centre) analyst | yash.mittal@acko.tech |
| user_growth | GIVA | User Growth Intelligence analyst | yash.agnihotri@acko.tech |
| retail_travel | AVI | Retail Travel Insurance analyst | parth.trivedi@acko.tech |
| escalation | ACE | Customer Escalation Expert | anurag.gupta1@acko.tech |
| fleetops_fia | FIA | Fleet Operations Intelligence analyst | anupam.singh@acko.tech |
| fleetops_fora | FORA | Fleet Operations RSA CRM analyst | anupam.singh@acko.tech |
| orchestrator | Orchestrator | Cross-pod — handles multi-LOB questions, reads taxonomy | yash.mittal@acko.tech |
| pod_builder | Pod Builder | Meta-skill — builds and maintains all other pods | yash.mittal@acko.tech |

## Structure

```
skills/
  <pod_id>/
    SKILL.md                   ← The governed skill file (source of truth for the analyst)
    semantic/
      metrics.csv              ← Canonical metric definitions (one row per metric)
    analyses/
      patterns.sql             ← Approved, parameterised SQL patterns
    evals/
      metric_evals.yaml        ← Golden-answer evals; CI fails if these regress
registry/
  router.yaml                  ← Cross-pod routing rules
access/
  pods.yaml                    ← Least-privilege BigQuery grants per pod
```

## Claude Project Setup

The file `shared/SYSTEM_PROMPT.md` is the single source of truth for the Claude Project instructions.
When it changes: edit in repo → PR → merge → copy contents → paste into Claude Project instructions.
Users need no connectors, no GitHub access, no configuration. They just open the project and ask.

## 4-File Contract (Per Pod)

| File | Purpose | Who edits |
|---|---|---|
| `SKILL.md` | Full analyst behaviour, tables, metric definitions, SQL rules | Analyst via Pod Builder |
| `semantic/metrics.csv` | Metric catalogue — name, table, SQL fragment, grain, owner | Analyst via Pod Builder |
| `analyses/patterns.sql` | Parameterised SQL patterns for RCA and standard queries | Analyst via Pod Builder |
| `evals/metric_evals.yaml` | Golden answers for CI regression testing | Auto-captured from ✓ feedback or manually by analyst |

## Workflow

Analysts never touch GitHub directly. All changes go through **Pod Builder** (Claude conversation):

1. Analyst describes a metric fix or new pattern in plain English.
2. Pod Builder generates file changes, shows a plain-English diff, asks for confirmation.
3. Pod Builder opens a PR with a description.
4. Manager gets a GitHub review request (email + Slack via standard GitHub integration) and approves in GitHub.
5. CI runs evals. Passes → merge. Fails → analyst is notified via GitHub and Pod Builder explains the error in plain English.

## CI Gates

- Schema validation: all tables in metrics.csv must exist in `INFORMATION_SCHEMA.COLUMNS`.
- Eval regression: all `status: confirmed` evals must pass within `tolerance_pct`.
- PII scan: no raw phone/email columns in SQL patterns.
- Access check: tables in patterns.sql must be in the pod's `access/pods.yaml` grant list.

## Adding a New Pod

1. Create `skills/<new_pod_id>/` with the 4-file structure.
2. Add the pod to `registry/router.yaml` — one row in table_to_pod with table name and entity description.
3. Add the pod section to `shared/SYSTEM_PROMPT.md` — tables, rules, confirmed metrics.
4. Paste updated `SYSTEM_PROMPT.md` into the Claude Project instructions.
5. Add the pod to `access/pods.yaml` with dataset grants.
6. Open a PR. Platform owner reviews and merges.
