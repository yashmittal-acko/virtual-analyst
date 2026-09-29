# GitHub Setup Checklist

Steps required before the CI workflows will run. Do these once after pushing the repo to GitHub.

---

## 1. Fix CODEOWNERS usernames

Open `.github/CODEOWNERS` and replace the placeholder `@username` values with real GitHub usernames.

To find a GitHub username: go to `github.com/<username>` and confirm the page exists.

| Person | Email | GitHub username |
|---|---|---|
| Yash Mittal | yash.mittal@acko.tech | _confirm_ |
| Yash Agnihotri | yash.agnihotri@acko.tech | _confirm_ |
| Parth Trivedi | parth.trivedi@acko.tech | _confirm_ |
| Anurag Gupta | anurag.gupta1@acko.tech | _confirm_ |
| Anupam Singh | anupam.singh@acko.tech | _confirm_ |

---

## 2. Add GitHub repository secrets

Go to: **GitHub repo → Settings → Secrets and variables → Actions → New repository secret**

Add these two secrets (required for the eval CI and schema validator to authenticate to BigQuery):

| Secret name | Value |
|---|---|
| `GCP_WIF_PROVIDER` | Workload Identity Federation provider resource name. Format: `projects/<project_number>/locations/global/workloadIdentityPools/<pool>/providers/<provider>` |
| `GCP_SA_EMAIL` | Service account email. Format: `<sa-name>@storm-wall-185017.iam.gserviceaccount.com` |

The service account needs two IAM roles on `storm-wall-185017`:
- `roles/bigquery.dataViewer`
- `roles/bigquery.jobUser`

If you prefer a simpler setup (not Workload Identity), replace the `google-github-actions/auth` step in `.github/workflows/evals-ci.yml` with a `GOOGLE_CREDENTIALS` JSON key secret and use `credentials_json: ${{ secrets.GOOGLE_CREDENTIALS }}` instead.

---

## 3. Enable GitHub Actions

Go to: **GitHub repo → Settings → Actions → General**

Set to: **Allow all actions and reusable workflows**

---

## 4. Set default branch

The CI workflows run on pushes to `main`. Confirm your default branch is named `main`.  
If it's `master`, find and replace `branches: [main]` in `.github/workflows/guardrails-ci.yml`.

---

## 5. Invite team members as repo collaborators

Go to: **GitHub repo → Settings → Collaborators and teams**

Add each pod owner with at least **Write** access so they can be assigned as reviewers via CODEOWNERS.

---

## 6. Smoke test the CI

After completing steps 1–5, open a test PR that touches any file in `skills/adsc/`.

Expected behaviour:
- Yash Mittal gets a GitHub review request (email + Slack if GitHub-Slack is connected)
- `guardrails-ci.yml` runs and passes
- `evals-ci.yml` runs, hits BigQuery, and all 27 evals pass
- PR cannot be merged until Yash approves

---

## 7. Run promote.py for the first release

Once the test PR is merged:

```bash
pip install google-cloud-bigquery pyyaml
gcloud auth application-default login
python3 build/promote.py --all --dry-run   # check everything first
python3 build/promote.py --all             # tag all pods at v1.0.0
git push origin --tags
```

---

## One-time setup is done. Normal workflow from here:

Analysts use Pod Builder → Pod Builder opens PRs → GitHub notifies reviewers → reviewer approves in GitHub → CI passes → merge.
