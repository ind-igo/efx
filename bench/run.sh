#!/bin/sh
# Collects the numbers in the README's Performance section.
# RUNS sets the number of seeds; each seed runs forward, reverse and shuffled.
# Run on an idle machine. Raw CSVs stay in the directory printed at the end.
set -eu
cd "$(dirname "$0")/.."
runs=${RUNS:-5}
out=$(mktemp -d)
mkdir "$out/default" "$out/nofp" "$out/cold2"

zig build
bin=zig-out/bin

seed=1
while [ "$seed" -le "$runs" ]; do
    for mode in fwd rev shuf; do
        "$bin/bench-dispatch" "$mode" "$seed" all > "$out/default/$mode-$seed.csv"
    done
    "$bin/bench-dispatch" shuf "$seed" cold2 > "$out/cold2/shuf-$seed.csv"
    "$bin/bench-dispatch-nofp" shuf "$seed" mono > "$out/nofp/shuf-$seed.csv"
    seed=$((seed + 1))
done

for group in default nofp cold2; do
    echo "===== $group ====="
    python3 bench/analyze.py "$out/$group"
done
echo "Raw results: $out"
