#!/usr/bin/env python3
"""Render the month-end Discord post: miles, state guesses, and the guessr board.

    task tripbot:prod:leaderboards            # the month that just ended
    task tripbot:prod:leaderboards -- --month 2026-08

Prints one message to stdout, ready to paste into Discord. Run it on the 1st:
the miles and guess boards come from `scoreboard_snapshots`, which the rollup
reconciler writes on its first tick after rollover, so a month only becomes
readable once it is over.

Three boards from two places, because they are scored in different systems.
Miles and state guesses are tripbot's, read out of prod Postgres -- the cluster
has no inbound path, so the read goes through `kubectl exec` into the CNPG
primary rather than a connection string. The guessr board is a public JSON read
from the game's own API, which is the same fetch the onscreen overlay does.

Nothing here mutates anything: one SELECT and one GET.
"""

import argparse
import json
import subprocess
import sys
import urllib.error
import urllib.request
from calendar import month_name
from datetime import date, timedelta

GUESSR_API = "https://guessr.dana.lol/api/leaderboard"

# Board names embed their month as a _YYYY_MM suffix (miles_2026_08), which is
# the identity they are queried by everywhere else -- pkg/rollups writes them,
# pkg/server/stats.go reads them back.
# Each board with the heading it posts under and how many decimals its score
# wants: miles accrue continuously, a guess is a whole number of correct ones.
BOARDS = [
    ("miles", "🛣️ Miles", 1),
    ("guess_state", "🗺️ State guesses", 0),
]

# The snapshot holds fifty placements per board; a Discord post wants a board
# somebody will read to the end of.
ROWS = 10

# Rows come back one per line, columns pipe-separated. Safe as a separator
# because a Twitch username is [a-zA-Z0-9_] -- there is no name that could
# carry one and split its own row.
SNAPSHOT_SQL = """
SELECT username, value
  FROM scoreboard_snapshots
 WHERE scoreboard_name = '{board}_{suffix}' AND platform = '{platform}'
 ORDER BY rank
"""


def previous_month(today=None):
    """The month that just ended, as YYYY-MM."""
    # The day before the 1st is the last day of the month before, which spares
    # us the January case that would otherwise have to wrap the year by hand.
    first = (today or date.today()).replace(day=1)
    return (first - timedelta(days=1)).strftime("%Y-%m")


def ranked(rows):
    """Number rows for display: equal scores share a rank, and the next one skips.

    Recomputed from the values rather than read off the snapshot's own `rank`
    column, which is dense and unique -- two players on 2 guesses are stored as
    2nd and 3rd, and printing that names a winner between them that the scores
    do not support.

    Rows arrive best-first and stay in that order; only the numbers change.
    """
    out = []
    for i, (name, value) in enumerate(rows):
        rank = out[-1][0] if out and out[-1][2] == value else i + 1
        out.append((rank, name, value))
    return out


def fmt(value, decimals):
    return f"{value:,.{decimals}f}"


def board_lines(rows, decimals):
    """A board as Discord lines, or None if nobody placed on it.

    A zero score is not a placement -- the guess board carries every logged-in
    viewer, and forty of them never guessed -- so those rows are dropped before
    the ranking rather than printed as a tie for last.
    """
    scored = [(name, value) for name, value in rows if value > 0][:ROWS]
    if not scored:
        return None
    return [
        f"{rank}. {name} — {fmt(value, decimals)}"
        for rank, name, value in ranked(scored)
    ]


def snapshot_board(board, month, namespace, platform):
    """One tripbot board, read from the snapshot table in the CNPG primary."""
    sql = SNAPSHOT_SQL.format(
        board=board, suffix=month.replace("-", "_"), platform=platform
    )
    # By label rather than by pod name: `pg-1` is the primary today, and after a
    # failover it is whichever instance took over.
    selector = "cnpg.io/cluster=pg,role=primary"
    pod = run(*f"kubectl -n {namespace} get pod -l {selector} -o name".split()).strip()
    if not pod:
        sys.exit(f"no CNPG primary found in {namespace}")
    # The SQL stays its own argument -- split() would tear it apart on its spaces.
    out = run(
        *f"kubectl -n {namespace} exec {pod} -c postgres -- psql -U postgres -d tripbot -tAc".split(),
        sql,
    )
    rows = []
    for line in out.splitlines():
        if not line.strip():
            continue
        name, value = line.rsplit("|", 1)
        rows.append((name, float(value)))
    return rows


def guessr_board(month):
    """The guessr board for a month that has ended.

    The endpoint served only the running month until guessr#170; an older deploy
    ignores `month` and answers with today's board instead, which would paste a
    September board under an August heading. `period` is the response saying
    which month it actually summed, so it is checked rather than assumed.
    """
    url = f"{GUESSR_API}?board=monthly&month={month}"
    # Named, because Cloudflare answers urllib's default agent with a 1010
    # block page rather than the board.
    req = urllib.request.Request(
        url, headers={"user-agent": "adanalife-monthly-leaderboards"}
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            body = json.load(resp)
    except urllib.error.HTTPError as e:
        sys.exit(f"guessr board: {url} answered {e.code} {e.read().decode()[:200]}")
    except OSError as e:
        sys.exit(f"guessr board: {url} unreachable ({e})")
    if body.get("period") != month:
        sys.exit(
            f"guessr board: asked for {month}, got {body.get('period')!r} -- "
            "the deploy predates the month parameter (guessr#170)"
        )
    return [(name, points) for name, points in body["rows"]]


def run(*argv):
    proc = subprocess.run(argv, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit(f"{argv[0]} failed: {proc.stderr.strip() or proc.stdout.strip()}")
    return proc.stdout


def message(month, boards):
    """The post itself. Boards with nobody on them are left out, not printed empty."""
    year, mon = month.split("-")
    out = [
        f"🏁 **{month_name[int(mon)]} {year} final leaderboards** 🏁",
        "The slate's wiped, the new month is running. Here's how it ended.",
    ]
    for heading, lines in boards:
        if lines:
            out += ["", f"**{heading}**", *lines]
    out += ["", "Congrats all — see you on this month's boards. 🚐"]
    return "\n".join(out)


def self_check():
    assert ranked([("a", 5.0), ("b", 3.0)]) == [(1, "a", 5.0), (2, "b", 3.0)]
    # A tie shares its rank and the next row skips past both of them.
    assert [r for r, _, _ in ranked([("a", 2), ("b", 2), ("c", 1)])] == [1, 1, 3]
    assert [r for r, _, _ in ranked([("a", 9), ("b", 2), ("c", 2)])] == [1, 2, 2]
    assert board_lines([("a", 0), ("b", 0)], 0) is None
    assert board_lines([("a", 3.0), ("b", 0)], 1) == ["1. a — 3.0"]
    assert board_lines([("a", 1512.7377)], 1) == ["1. a — 1,512.7"]
    # Day zero arithmetic, including the January case that wraps the year.
    assert previous_month(date(2026, 9, 1)) == "2026-08"
    assert previous_month(date(2026, 1, 15)) == "2025-12"
    assert previous_month(date(2026, 3, 1)) == "2026-02"
    print("ok: ranks share on ties, zero scores do not place, months step back")


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--month", help="YYYY-MM (default: the month that just ended)")
    p.add_argument(
        "--namespace", default="prod-1-data", help="where the CNPG cluster lives"
    )
    p.add_argument(
        "--platform", default="twitch", help="which platform's boards to read"
    )
    p.add_argument(
        "--self-check", action="store_true", help="run the assertions and exit"
    )
    args = p.parse_args()

    if args.self_check:
        return self_check()

    month = args.month or previous_month()
    boards = [
        (
            heading,
            board_lines(
                snapshot_board(board, month, args.namespace, args.platform), decimals
            ),
        )
        for board, heading, decimals in BOARDS
    ]
    boards.append(("🎮 guessr", board_lines(guessr_board(month), 0)))
    print(message(month, boards))


if __name__ == "__main__":
    main()
