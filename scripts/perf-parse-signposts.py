#!/usr/bin/env python3
"""Parse os_signpost begin/end pairs from a `/usr/bin/log show --signpost`
output (compact style) and print a per-signpost duration table.

Usage:
    python3 scripts/perf-parse-signposts.py <log-file>

Pairs each begin with the next end of the same name on the same thread,
so concurrent same-name signposts on different threads do not collide.
Stdlib only; expects Python 3.
"""
import re
import sys
from collections import defaultdict, deque
from datetime import datetime


LINE_RE = re.compile(
    r'^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+).+?'
    r'\[\d+:([0-9a-f]+)\].*?process,\s+(begin|end)\]\s+(.+)$'
)


def parse(path):
    durations = defaultdict(list)
    in_flight = defaultdict(deque)
    with open(path) as fh:
        for line in fh:
            m = LINE_RE.match(line)
            if not m:
                continue
            ts_str, tid, kind, name = m.groups()
            ts = datetime.strptime(ts_str, "%Y-%m-%d %H:%M:%S.%f")
            key = (tid, name.strip())
            if kind == 'begin':
                in_flight[key].append(ts)
            elif in_flight[key]:
                begin_ts = in_flight[key].pop()
                durations[name.strip()].append(
                    (ts - begin_ts).total_seconds() * 1000
                )
    return durations


def main():
    if len(sys.argv) != 2:
        print("usage: perf-parse-signposts.py <log-file>", file=sys.stderr)
        sys.exit(2)
    durations = parse(sys.argv[1])
    if not durations:
        print("No signpost intervals parsed.")
        return
    header = (
        f"{'Signpost':<50} {'N':>4} {'Sum (ms)':>10} "
        f"{'Avg':>8} {'Min':>8} {'Max':>8} {'p95':>8}"
    )
    print(header)
    print('-' * len(header))
    for name in sorted(durations):
        ds = durations[name]
        n = len(ds)
        total = sum(ds)
        avg = total / n
        mn, mx = min(ds), max(ds)
        p95 = sorted(ds)[int(n * 0.95)] if n >= 5 else mx
        print(
            f"{name:<50} {n:>4} {total:>10.1f} "
            f"{avg:>8.2f} {mn:>8.2f} {mx:>8.2f} {p95:>8.2f}"
        )


if __name__ == "__main__":
    main()
