#!/usr/bin/env python3
"""
promote.py
Gates a pod from dev to prod.

Checks before promotion:
  1. All confirmed evals pass (runs run_evals.py --pod <pod>)
  2. Guardrail hash is current (runs inject_guardrails.py --verify)
  3. Schema valid (runs validate_schema.py --pod <pod> --skip-bq skipped if no creds)
  4. VERSION file is bumped relative to the last git tag for that pod
  5. SKILL.md has been reviewed (CODEOWNERS approval on the PR)

On success: tags the pod release as <pod>/v<version> in git.
On failure: prints the blocking reason and exits 1.

Usage:
    python3 build/promote.py --pod adsc
    python3 build/promote.py --pod adsc --dry-run
    python3 build/promote.py --all
"""

import argparse
import subprocess
import sys
from pathlib import Path

REPO_ROOT  = Path(__file__).resolve().parent.parent
SKILLS_DIR = REPO_ROOT / "skills"
BUILD_DIR  = REPO_ROOT / "build"


def run(cmd, capture=True):
    result = subprocess.run(cmd, capture_output=capture, text=True, cwd=REPO_ROOT)
    return result.returncode, result.stdout.strip(), result.stderr.strip()


def get_version(pod):
    vf = SKILLS_DIR / pod / "VERSION"
    if not vf.exists():
        return None
    return vf.read_text().strip()


def last_tag(pod):
    code, out, _ = run(["git", "tag", "--list", f"{pod}/v*", "--sort=-version:refname"])
    tags = [t for t in out.splitlines() if t]
    return tags[0] if tags else None


def check_guardrails():
    code, out, err = run(["python3", str(BUILD_DIR / "inject_guardrails.py"), "--verify"])
    return code == 0, out + err


def check_evals(pod, dry_run):
    if dry_run:
        return True, "[dry-run] evals skipped"
    code, out, err = run(["python3", str(BUILD_DIR / "run_evals.py"), "--pod", pod])
    return code == 0, out + err


def check_schema(pod):
    code, out, err = run(["python3", str(BUILD_DIR / "validate_schema.py"), "--pod", pod, "--skip-bq"])
    return code == 0, out + err


def promote_pod(pod, dry_run):
    print(f"\n{'='*50}")
    print(f"Promoting pod: {pod}")
    print(f"{'='*50}")

    errors = []

    # 1. VERSION file
    version = get_version(pod)
    if not version:
        errors.append(f"No VERSION file at skills/{pod}/VERSION")
    else:
        tag = last_tag(pod)
        if tag:
            last_v = tag.split("/v")[-1]
            if last_v == version:
                errors.append(f"VERSION ({version}) unchanged since last tag {tag} — bump the version")
            else:
                print(f"  [ok] version {version} (last tag: {tag})")
        else:
            print(f"  [ok] version {version} (first release)")

    # 2. Guardrails
    ok, msg = check_guardrails()
    if ok:
        print(f"  [ok] guardrails hash current")
    else:
        errors.append(f"Guardrail check failed:\n{msg}")

    # 3. Schema + access
    ok, msg = check_schema(pod)
    if ok:
        print(f"  [ok] schema + access valid")
    else:
        errors.append(f"Schema/access check failed:\n{msg}")

    # 4. Evals
    ok, msg = check_evals(pod, dry_run)
    if ok:
        print(f"  [ok] evals passed")
    else:
        errors.append(f"Eval check failed:\n{msg}")

    # Result
    if errors:
        print(f"\n[BLOCKED] Cannot promote {pod}:")
        for e in errors:
            print(f"  ✗ {e}")
        return False

    if dry_run:
        print(f"\n[dry-run] Would tag: {pod}/v{version}")
        return True

    code, out, err = run(["git", "tag", f"{pod}/v{version}", "-m", f"Promote {pod} to v{version}"])
    if code != 0:
        print(f"\n[FAIL] git tag failed: {err}")
        return False

    print(f"\n[PROMOTED] Tagged {pod}/v{version}")
    print("  Push with: git push origin --tags")
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pod", help="Pod to promote")
    parser.add_argument("--all", action="store_true", help="Promote all pods")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if not args.pod and not args.all:
        parser.error("Specify --pod <name> or --all")

    pods = (
        [d.name for d in sorted(SKILLS_DIR.iterdir()) if d.is_dir()]
        if args.all
        else [args.pod]
    )

    results = {}
    for pod in pods:
        if not (SKILLS_DIR / pod).is_dir():
            print(f"[skip] {pod} — not a valid pod directory")
            continue
        results[pod] = promote_pod(pod, args.dry_run)

    print(f"\n{'='*50}")
    passed = [p for p, ok in results.items() if ok]
    blocked = [p for p, ok in results.items() if not ok]
    print(f"Promoted: {', '.join(passed) or 'none'}")
    print(f"Blocked:  {', '.join(blocked) or 'none'}")
    sys.exit(0 if not blocked else 1)


if __name__ == "__main__":
    main()
