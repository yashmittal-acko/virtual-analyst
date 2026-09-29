#!/usr/bin/env python3
"""
inject_guardrails.py
Prepends the universal guardrail block into every pod SKILL.md.
Run this whenever GUARDRAILS.md changes — it is the single source of truth.

Usage:
    python3 build/inject_guardrails.py          # inject into all pods
    python3 build/inject_guardrails.py --dry-run # preview diffs, write nothing
    python3 build/inject_guardrails.py --pod adsc # single pod only

CI: run this in the PR check. Fail the PR if any SKILL.md does not contain
    the current guardrail hash (i.e. someone edited SKILL.md directly).
"""

import argparse
import hashlib
import os
import re
import sys
from pathlib import Path

REPO_ROOT   = Path(__file__).resolve().parent.parent
GUARDRAILS  = REPO_ROOT / "shared" / "GUARDRAILS.md"
SKILLS_DIR  = REPO_ROOT / "skills"

GUARD_START = "<!-- GUARDRAILS:START -->"
GUARD_END   = "<!-- GUARDRAILS:END -->"
HASH_TAG    = "<!-- GUARDRAILS:SHA256:"


def guardrail_block(raw: str) -> str:
    sha = hashlib.sha256(raw.encode()).hexdigest()[:16]
    return f"{GUARD_START}\n{raw.rstrip()}\n{GUARD_END}\n{HASH_TAG}{sha} -->\n"


def strip_existing(content: str) -> str:
    """Remove any previously injected guardrail block."""
    pattern = re.compile(
        rf"{re.escape(GUARD_START)}.*?{re.escape(GUARD_END)}\n?{re.escape(HASH_TAG)}[0-9a-f]{{16}} -->\n?",
        re.DOTALL,
    )
    return pattern.sub("", content)


def inject(skill_path: Path, block: str, dry_run: bool) -> bool:
    raw = skill_path.read_text(encoding="utf-8")

    # Separate YAML front-matter (--- ... ---) from body
    fm_match = re.match(r"^(---\n.*?\n---\n)", raw, re.DOTALL)
    if fm_match:
        frontmatter = fm_match.group(1)
        body = raw[len(frontmatter):]
    else:
        frontmatter = ""
        body = raw

    body_clean = strip_existing(body)
    new_content = frontmatter + block + "\n" + body_clean.lstrip("\n")

    if new_content == raw:
        print(f"  [skip]    {skill_path.relative_to(REPO_ROOT)}  (already current)")
        return False

    if dry_run:
        print(f"  [dry-run] {skill_path.relative_to(REPO_ROOT)}  (would update)")
        return True

    skill_path.write_text(new_content, encoding="utf-8")
    print(f"  [updated] {skill_path.relative_to(REPO_ROOT)}")
    return True


def verify_all() -> bool:
    """Check every SKILL.md contains the current guardrail hash. Used in CI."""
    guard_raw = GUARDRAILS.read_text(encoding="utf-8")
    sha = hashlib.sha256(guard_raw.encode()).hexdigest()[:16]
    expected_tag = f"{HASH_TAG}{sha} -->"
    ok = True
    for skill_path in sorted(SKILLS_DIR.glob("*/SKILL.md")):
        content = skill_path.read_text(encoding="utf-8")
        if expected_tag not in content:
            print(f"  [FAIL] {skill_path.relative_to(REPO_ROOT)} — guardrail not injected or out of date")
            ok = False
        else:
            print(f"  [ok]   {skill_path.relative_to(REPO_ROOT)}")
    return ok


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--pod", help="Only inject into this pod (e.g. adsc)")
    parser.add_argument("--verify", action="store_true", help="CI check: verify all files have current hash")
    args = parser.parse_args()

    if args.verify:
        ok = verify_all()
        sys.exit(0 if ok else 1)

    guard_raw = GUARDRAILS.read_text(encoding="utf-8")
    block = guardrail_block(guard_raw)

    if args.pod:
        paths = [SKILLS_DIR / args.pod / "SKILL.md"]
    else:
        paths = sorted(SKILLS_DIR.glob("*/SKILL.md"))

    updated = 0
    for p in paths:
        if not p.exists():
            print(f"  [missing] {p}")
            continue
        if inject(p, block, args.dry_run):
            updated += 1

    action = "would update" if args.dry_run else "updated"
    print(f"\n{action} {updated} of {len(paths)} skill files.")


if __name__ == "__main__":
    main()
