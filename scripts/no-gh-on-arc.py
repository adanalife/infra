#!/usr/bin/env python3
"""Refuse a `gh` invocation in a workflow that runs on the self-hosted ARC pool.

`ghcr.io/actions/actions-runner` ships `curl` and `jq` but no `gh`, so a step
shelling out to `gh` exits 127 there. It hides well: the calls that reach for
`gh` tend to sit behind `if: failure()` or a `schedule:`, which never fire on a
green repo, so the breakage surfaces weeks later at the worst moment.

The parse is deliberately cheap. `runs-on` can be a matrix expression, so a
file counts as ARC when the literal `arc-` appears anywhere in it — mixed-runner
files get false positives, and the escape hatch is the marker below.

    scripts/no-gh-on-arc.py .github/workflows/*.yml
    scripts/no-gh-on-arc.py --self-test
"""

import re
import sys

MARKER = "gh-on-arc: ok"
GH = re.compile(r"(?<![\w./$-])gh\s")
RUN = re.compile(r"(?:-\s+)?run:")


def offenders(text: str) -> list[int]:
    """Line numbers of `gh` calls inside `run:` blocks of an ARC workflow."""
    if MARKER in text or "arc-" not in text:
        return []
    hits = []
    run_indent = None
    for lineno, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        if run_indent is not None and indent <= run_indent:
            run_indent = None
        if run_indent is None:
            match = RUN.match(line.strip())
            if not match:
                continue
            run_indent = indent
            body = line.strip()[match.end() :]
        else:
            body = line
        if GH.search(body):
            hits.append(lineno)
    return hits


def self_test() -> None:
    bad = """
jobs:
  gate:
    runs-on: arc-amd64
    steps:
      - run: gh api repos/foo/bar > out.json
"""
    good_curl = bad.replace("gh api repos/foo/bar", "curl -fsSL https://api.github.com")
    good_hosted = bad.replace("arc-amd64", "ubuntu-latest")
    good_marker = bad.replace("- run:", "# gh-on-arc: ok\n      - run:")
    multiline = """
jobs:
  gate:
    runs-on: [self-hosted, arc-amd64]
    steps:
      - name: report
        run: |
          set -e
          gh pr comment 1 --body hi
      - run: echo done
"""
    not_gh = bad.replace("gh api", "highlight")
    assert offenders(bad) == [6], offenders(bad)
    assert offenders(good_curl) == []
    assert offenders(good_hosted) == []
    assert offenders(good_marker) == []
    assert offenders(multiline) == [9], offenders(multiline)
    assert offenders(not_gh) == []
    print("ok")


def main(argv: list[str]) -> int:
    if argv[:1] == ["--self-test"]:
        self_test()
        return 0
    failed = False
    for path in argv:
        with open(path, encoding="utf-8") as handle:
            hits = offenders(handle.read())
        for lineno in hits:
            failed = True
            print(
                f"{path}:{lineno}: the ARC image has no gh — curl the REST API instead"
            )
    if failed:
        print(f"\nDeliberate? Put a `# {MARKER}` comment anywhere in the file.")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
