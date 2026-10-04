#!/usr/bin/env python3
"""Apply one mutation, described by apply-mutations.tsv, to a copy of apply.sh.

Reads:   good.sh out.sh match replace skip_next [nth]
Matches: whole lines CONTAINING `match` as a substring.

nth selects which match to rewrite, 1-based, so that a substring appearing in two
functions can be mutated in one of them -- `forward_declarations` is called from
both sync_network_forward and report_existing_drift, and those two fixes are
independent. nth=0 rewrites every match, for a substitution that is genuinely the
same in both places.

A bare assertion that nothing matched is not enough: the first version of this
script failed three times in a row reporting "site not found", which looks exactly
like a real result. So an ambiguous or absent match prints what it wanted and
what it found, and exits non-zero either way.
"""
import sys

good, out, match, replace, skip_next = sys.argv[1:6]
nth = int(sys.argv[6]) if len(sys.argv) > 6 else 1
skip_next = skip_next.strip() == "1"

src = open(good, encoding="utf-8").read()
lines = src.split("\n")

hits = [i for i, l in enumerate(lines) if match in l]
if not hits:
    sys.stderr.write("no line contains %r\n" % match)
    # Show something close, so a stale mutation spec is obvious.
    head = match.split()[0] if match.split() else match
    for l in [l for l in lines if head in l][:3]:
        sys.stderr.write("  nearby: %r\n" % l)
    sys.exit(2)
if nth == 0:
    if len(hits) != 1 and len(hits) < 2:
        sys.exit(2)
    chosen = hits
elif nth > len(hits):
    sys.stderr.write("%r matches %d line(s); asked for #%d\n" % (match, len(hits), nth))
    sys.exit(2)
else:
    chosen = [hits[nth - 1]]

# Walk backwards so the deletions below do not shift the indices still to come.
for i in sorted(chosen, reverse=True):
    lines[i] = replace
    if skip_next:
        if i + 1 >= len(lines):
            sys.stderr.write("skip_next=1 but %r is the last line\n" % match)
            sys.exit(2)
        del lines[i + 1]

open(out, "w", encoding="utf-8").write("\n".join(lines))
