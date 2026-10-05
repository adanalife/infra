#!/usr/bin/env python3
"""Fail when a Grafana alert queries a metric the cloud keep-list drops.

Every Prometheus alert rule in terraform/platform/grafana-alerts.tf reads the
Grafana Cloud datasource, and the only cluster metrics that reach Grafana Cloud
are the ones the Alloy `keep` rule in k8s/monitoring/prod-1/values.yml lets
through. A rule on a metric that rule drops is valid PromQL, plans clean, and
never fires: it reads no data, which most rules map to OK. This keeps a new
alert and its keep-list entry in the same change.

Metric names are pulled out of each expression by stripping strings, label
matchers, grouping clauses, ranges and offsets, then dropping function calls
and keywords — a heuristic, not a PromQL parser, so an expression it misreads
shows up here as an unknown name rather than passing quietly.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ALERTS = ROOT / "terraform/platform/grafana-alerts.tf"
VALUES = ROOT / "k8s/monitoring/prod-1/values.yml"
CLOUD_DATASOURCE = "data.grafana_data_source.prometheus.uid"

# Written straight into Grafana Cloud, never through Alloy, so the keep rule
# never sees them.
DIRECT = (
    re.compile(r"probe_.+"),  # Synthetic Monitoring checks
)

KEYWORDS = {
    "by",
    "without",
    "on",
    "ignoring",
    "group_left",
    "group_right",
    "offset",
    "bool",
    "and",
    "or",
    "unless",
    "inf",
    "nan",
}


def keep_regex() -> re.Pattern:
    text = VALUES.read_text()
    m = re.search(r'regex\s*=\s*"((?:\\.|[^"\\])*)"\s*\n\s*action\s*=\s*"keep"', text)
    if not m:
        sys.exit(f"{VALUES.relative_to(ROOT)}: no keep rule found")
    # An Alloy string literal: \\ is one backslash.
    return re.compile(m.group(1).replace("\\\\", "\\"))


def selectors(expr: str) -> list[tuple[str, str]]:
    """(metric, mountpoint) for every series selector in a PromQL expression."""
    e = re.sub(r"\$\{[^}]*\}", "", expr)
    mounts = {}
    for m in re.finditer(r"([A-Za-z_:][A-Za-z0-9_:]*)\{([^}]*)\}", e):
        mp = re.search(r'mountpoint\s*=\s*"([^"]*)"', m.group(2))
        if mp:
            mounts[m.group(1)] = mp.group(1)
    e = re.sub(r'"(?:\\.|[^"\\])*"', "", e)
    e = re.sub(r"\{[^}]*\}", "", e)
    e = re.sub(r"\b(by|without|on|ignoring|group_left|group_right)\s*\([^)]*\)", "", e)
    e = re.sub(r"\[[^\]]*\]", "", e)
    e = re.sub(r"\boffset\s+-?\w+", "", e)
    e = re.sub(r"\b\d[\w.]*", "", e)
    found = []
    for m in re.finditer(r"[A-Za-z_:][A-Za-z0-9_:]*", e):
        name = m.group(0)
        if name in KEYWORDS or e[m.end() :].lstrip().startswith("("):
            continue
        found.append((name, mounts.get(name, "")))
    return found


def main() -> int:
    keep = keep_regex()
    datasource = None
    bad = []
    for lineno, line in enumerate(ALERTS.read_text().splitlines(), 1):
        if m := re.search(r"datasource_uid\s*=\s*(\S+)", line):
            datasource = m.group(1)
        m = re.match(r'\s*expr\s*=\s*"(.*)"\s*$', line)
        if not m or datasource != CLOUD_DATASOURCE:
            continue
        for name, mount in selectors(m.group(1).replace('\\"', '"')):
            if any(d.fullmatch(name) for d in DIRECT):
                continue
            # The keep rule matches __name__ and mountpoint joined by "/".
            if not keep.fullmatch(f"{name}/{mount}"):
                bad.append(
                    f"{ALERTS.relative_to(ROOT)}:{lineno}: {name}"
                    + (f' (mountpoint="{mount}")' if mount else "")
                )
    for b in bad:
        print(f"{b} — not in the Grafana Cloud keep rule in {VALUES.relative_to(ROOT)}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
