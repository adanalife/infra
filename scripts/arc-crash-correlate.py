#!/usr/bin/env python3
"""Correlate minipc node deaths with the CI jobs that were running at the time.

Answers one question: when the single-node Talos cluster reboots under it, is a
self-hosted (ARC) runner job on the box, and does one (repo, workflow, job)
account for a disproportionate share of the deaths? Node conditions are useless
here — on a single-node cluster nothing survives to mark the node NotReady — so
the census comes from `node_boot_time_seconds` in the in-cluster VictoriaMetrics,
which is retained locally and not shipped to Grafana Cloud.

    kubectl -n monitoring port-forward svc/victoria-metrics 8428 &
    scripts/arc-crash-correlate.py --since 2026-08-22

or `task arc:crash-correlate -- --since 2026-08-22`, which port-forwards for you.

Two traps this exists to walk around:

  * **Per-attempt jobs.** `…/runs/<id>/jobs` returns only the *latest* attempt,
    so any job a crash killed and a human re-ran vanishes from the crash window —
    exactly the jobs the analysis is about. Every attempt 1..run_attempt gets its
    own `…/runs/<id>/attempts/<n>/jobs` call, which is why the fetch is ~500 API
    calls and lands in a cache file (`--refresh` to re-fetch).

  * **A scrape gap is not a death.** A gap in the boot-time series means the
    metric stopped arriving, which happens when the node dies *and* when the
    scrape hiccups. A death additionally requires the boot value to change across
    the gap. `boot − last_sample` of ~2-3 min is the box rebooting itself
    (kernel `panic=10`); minutes-to-hours means a human power-cycled it.
"""

import argparse
import concurrent.futures
import json
import math
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

ORG = "adanalife"
# Consecutive samples further apart than this are a gap in the series. The
# scrape interval is well under a minute, so 90s clears normal jitter.
GAP_SECONDS = 90
# A death lands somewhere between the last sample and the next scrape that never
# came; jobs still running anywhere in that span count as concurrent.
DEATH_UNCERTAINTY = timedelta(seconds=60)
# A self-reboot is back in ~2-3 min (POST + Talos boot). Anything slower waited
# on a human.
SELF_REBOOT_MAX = timedelta(minutes=6)


def parse_ts(value):
    """Parse a GitHub/RFC3339 UTC timestamp."""
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def fmt(when):
    return when.strftime("%Y-%m-%dT%H:%M:%SZ")


def gh_api(path):
    """One paginated `gh api` call, returned as the list of pages."""
    proc = subprocess.run(
        ["gh", "api", "--paginate", "--slurp", path],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode:
        print(f"gh api {path}: {proc.stderr.strip()[:200]}", file=sys.stderr)
        return []
    return json.loads(proc.stdout)


def repo_jobs(repo, since, label):
    """Every job on the given runner label in `repo`, across all run attempts."""
    found = []
    runs = [
        run
        for page in gh_api(
            f"repos/{ORG}/{repo}/actions/runs?created=>={since}&per_page=100"
        )
        for run in page["workflow_runs"]
    ]
    for run in runs:
        for attempt in range(1, run["run_attempt"] + 1):
            for page in gh_api(
                f"repos/{ORG}/{repo}/actions/runs/{run['id']}"
                f"/attempts/{attempt}/jobs?per_page=100"
            ):
                for job in page["jobs"]:
                    if label not in (job.get("labels") or []):
                        continue
                    found.append(
                        {
                            "repo": repo,
                            "workflow": run["name"],
                            "branch": run["head_branch"],
                            "run": run["id"],
                            "attempt": attempt,
                            "job": job["name"],
                            "runner": job.get("runner_name"),
                            "started": job["started_at"],
                            "completed": job["completed_at"],
                            "conclusion": job["conclusion"],
                            "steps": [
                                {
                                    "name": step["name"],
                                    "started": step["started_at"],
                                    "completed": step["completed_at"],
                                }
                                for step in job.get("steps") or []
                            ],
                        }
                    )
    print(f"  {repo}: {len(runs)} runs, {len(found)} {label} jobs", file=sys.stderr)
    return found


def fetch_jobs(since, label):
    repos = subprocess.run(
        [
            "gh",
            "repo",
            "list",
            ORG,
            "--limit",
            "100",
            "--json",
            "name",
            "--jq",
            ".[].name",
        ],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    print(
        f"fetching {label} jobs since {since} across {len(repos)} repos…",
        file=sys.stderr,
    )
    jobs = []
    with concurrent.futures.ThreadPoolExecutor(4) as pool:
        for result in pool.map(lambda r: repo_jobs(r, since, label), repos):
            jobs += result
    return jobs


def load_jobs(cache, since, label, refresh):
    """Cached `fetch_jobs` — the fetch is ~500 API calls and a couple of minutes."""
    if not refresh and cache.exists():
        cached = json.loads(cache.read_text())
        if cached.get("since") == since and cached.get("label") == label:
            print(
                f"using cached jobs from {cache} (--refresh to re-fetch)",
                file=sys.stderr,
            )
            return cached["jobs"]
    jobs = fetch_jobs(since, label)
    cache.write_text(json.dumps({"since": since, "label": label, "jobs": jobs}))
    return jobs


def fetch_boot_samples(vm_url, window, instance):
    """Raw `node_boot_time_seconds` samples for one instance, oldest first."""
    query = urllib.parse.urlencode({"query": f"node_boot_time_seconds[{window}]"})
    url = f"{vm_url.rstrip('/')}/api/v1/query?{query}"
    try:
        with urllib.request.urlopen(url, timeout=30) as response:
            payload = json.load(response)
    except OSError as err:
        sys.exit(
            f"cannot reach VictoriaMetrics at {vm_url} ({err}) — "
            "kubectl -n monitoring port-forward svc/victoria-metrics 8428"
        )
    # The exporter is scraped twice (once per node name, once via the service
    # endpoint), so pick the node-named series rather than merging: two scrapes
    # of the same exporter share every gap, and a union would paper over one.
    for series in payload["data"]["result"]:
        if series["metric"].get("instance") == instance:
            # NaN samples are staleness markers written when the scrape target
            # vanishes — the death itself, not a reading. They compare unequal to
            # everything (themselves included), so leaving them in both invents
            # boots and hands an unconvertible timestamp to the death report.
            return sorted(
                (datetime.fromtimestamp(ts, timezone.utc), float(value))
                for ts, value in series["values"]
                if not math.isnan(float(value))
            )
    known = sorted({s["metric"].get("instance") for s in payload["data"]["result"]})
    sys.exit(f"no node_boot_time_seconds series for instance={instance}; saw {known}")


def find_deaths(samples):
    """Gaps in the series where the boot value also changed = the node restarted."""
    deaths = []
    for (last_ts, last_boot), (next_ts, next_boot) in zip(samples, samples[1:]):
        if (next_ts - last_ts).total_seconds() <= GAP_SECONDS:
            continue
        if next_boot == last_boot:
            continue  # scrape gap: the box never rebooted
        deaths.append((last_ts, datetime.fromtimestamp(next_boot, timezone.utc)))
    return deaths


def running_at(jobs, death):
    """Jobs whose execution overlaps the window the death happened in."""
    live = []
    for job in jobs:
        if not job["started"]:
            continue
        started = parse_ts(job["started"])
        if started > death + DEATH_UNCERTAINTY:
            continue
        if job["completed"] and parse_ts(job["completed"]) < death:
            continue
        live.append(job)
    return live


def active_step(job, death):
    """The step in flight at the death — the latest one to have started by then.

    Steps that a re-run or a cancellation stamped `completed` after the death
    overlap the window too, so take the last one to start rather than the first
    overlap.
    """
    live = [
        step
        for step in job["steps"]
        if step["started"]
        and parse_ts(step["started"]) <= death + DEATH_UNCERTAINTY
        and not (step["completed"] and parse_ts(step["completed"]) < death)
    ]
    return max(live, key=lambda s: s["started"])["name"] if live else "?"


def self_check():
    """Guard the two traps in the docstring with the smallest series that shows them."""
    start = datetime(2026, 8, 23, 3, 0, 0, tzinfo=timezone.utc)
    old, new = 1784500907.0, 1787454208.0
    samples = [
        (start, old),
        (start + timedelta(seconds=30), old),
        (start + timedelta(minutes=4), old),  # gap, same boot: a scrape hiccup
        (start + timedelta(minutes=5), old),
        (start + timedelta(minutes=9), new),  # gap, new boot: a death
    ]
    death = start + timedelta(minutes=5)
    assert find_deaths(samples) == [
        (death, datetime.fromtimestamp(new, timezone.utc))
    ], find_deaths(samples)

    job = {
        "started": fmt(start),
        "completed": None,
        "steps": [
            {"name": "Set up job", "started": fmt(start), "completed": fmt(start)},
            {
                "name": "Run pre-commit",
                "started": fmt(start + timedelta(minutes=1)),
                "completed": None,
            },
        ],
    }
    done = dict(job, completed=fmt(start + timedelta(minutes=1)))
    assert running_at([job, done], death) == [job]
    assert active_step(job, death) == "Run pre-commit"
    print("self-check ok")


def main():
    parser = argparse.ArgumentParser(
        description="Correlate minipc reboots with the ARC runner jobs running at the time.",
        epilog="Needs a port-forward to the in-cluster VictoriaMetrics; see the module docstring.",
    )
    default_since = (datetime.now(timezone.utc) - timedelta(days=3)).strftime(
        "%Y-%m-%d"
    )
    parser.add_argument(
        "--since",
        default=default_since,
        help=f"earliest CI run / boot sample (default: {default_since})",
    )
    parser.add_argument(
        "--window",
        help="VictoriaMetrics lookback, e.g. 80h (default: derived from --since)",
    )
    parser.add_argument(
        "--label",
        default="arc-amd64",
        help="runner label to keep jobs for (default: arc-amd64)",
    )
    parser.add_argument(
        "--vm-url",
        default="http://localhost:8428",
        help="VictoriaMetrics base URL (default: %(default)s)",
    )
    parser.add_argument(
        "--instance",
        default="adanalife-minipc",
        help="node_boot_time_seconds instance label (default: %(default)s)",
    )
    parser.add_argument(
        "--cache",
        type=Path,
        default=Path(tempfile.gettempdir()) / "arc-crash-correlate-jobs.json",
        help="where the GitHub job fetch is cached (default: %(default)s)",
    )
    parser.add_argument(
        "--refresh",
        action="store_true",
        help="re-fetch the jobs even if the cache is warm",
    )
    parser.add_argument(
        "--self-check",
        action="store_true",
        help="run the offline assertions over a synthetic series and exit",
    )
    args = parser.parse_args()

    if args.self_check:
        self_check()
        return

    since_dt = parse_ts(
        f"{args.since}T00:00:00Z" if len(args.since) == 10 else args.since
    )
    window = (
        args.window
        or f"{int((datetime.now(timezone.utc) - since_dt).total_seconds() // 3600) + 1}h"
    )

    samples = fetch_boot_samples(args.vm_url, window, args.instance)
    samples = [s for s in samples if s[0] >= since_dt]
    if not samples:
        sys.exit(f"no boot samples for {args.instance} in the last {window}")
    deaths = find_deaths(samples)
    jobs = [
        j
        for j in load_jobs(args.cache, args.since, args.label, args.refresh)
        if j["started"]
    ]

    boots = len({value for _, value in samples})
    print(
        f"\n=== {args.instance}: {len(deaths)} deaths since {fmt(samples[0][0])} "
        f"({boots} distinct boots in a {window} window, {len(jobs)} {args.label} job attempts) ===\n"
    )
    print(f"{'died between':<22} {'back up':<22} {'gap':>9}  cause")
    for death, boot in deaths:
        gap = boot - death
        cause = "self-reboot" if gap <= SELF_REBOOT_MAX else "power-cycled by hand"
        rounded = timedelta(seconds=round(gap.total_seconds()))
        print(f"{fmt(death):<22} {fmt(boot):<22} {str(rounded):>9}  {cause}")

    print("\n=== what was running ===")
    hit = set()
    for death, _ in deaths:
        live = running_at(jobs, death)
        hit.update(id(job) for job in live)
        print(f"\n{fmt(death)}  ({len(live)} job(s))")
        for job in sorted(live, key=lambda j: j["started"]):
            print(
                f"  {job['repo']}/{job['workflow']} · {job['job']} "
                f"(attempt {job['attempt']}, run {job['run']}, {job['branch']}) "
                f"— step: {active_step(job, death)}"
            )

    counts = defaultdict(
        lambda: [0, 0]
    )  # (repo, workflow, job) -> [attempts, attempts hit]
    for job in jobs:
        key = (job["repo"], job["workflow"], job["job"])
        counts[key][0] += 1
        counts[key][1] += id(job) in hit

    print("\n=== per-job death rate ===")
    print(f"{'repo':<18} {'workflow':<22} {'job':<26} {'runs':>5} {'deaths':>7}")
    for (repo, workflow, job), (runs, hit) in sorted(
        counts.items(), key=lambda kv: (-kv[1][1], -kv[1][0])
    ):
        print(f"{repo:<18} {workflow:<22} {job:<26} {runs:>5} {hit:>7}")


if __name__ == "__main__":
    main()
