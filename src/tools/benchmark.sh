#!/usr/bin/env bash
# Profiles every demo for 20 s on a virtual X display (no window on the desktop) and copies
# the reports to profiles/bench/<label>/, with each demo's printed output in <demo>.log (the
# stress test's per-stage results). Run from the repository root inside `nix develop`:
#
#     src/tools/benchmark.sh before
#
# See CHANGELOG.md for how the results are compared and recorded.
set -u
label=${1:?usage: src/tools/benchmark.sh <label>}
out="profiles/bench/$label"
mkdir -p "$out"

newest_report() {
	find profiles -maxdepth 1 -name '*.txt' -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2
}

for demo in breakout tower_defense galcon stress; do
	# Xvfb is sometimes not ready in time; raylib then exits at once without a report.
	for attempt in 1 2 3; do
		before=$(newest_report)
		ZSE_PROFILE_SECONDS=20 env -u WAYLAND_DISPLAY nix shell nixpkgs#xvfb-run -c \
			xvfb-run -a -s '-screen 0 1600x900x24' odin run "src/demos/$demo" >"$out/$demo.log" 2>/dev/null
		report=$(newest_report)
		if [ -n "$report" ] && [ "$report" != "$before" ]; then
			cp "$report" "$out/$demo.txt"
			echo "== $demo"
			grep -E 'average|median|hitches|CPU usage|startup|shaders compiled|GPU BY LOOK' "$out/$demo.txt"
			grep '^stress:' "$out/$demo.log" || true
			break
		fi
		echo "$demo: no report on attempt $attempt, retrying"
	done
done
