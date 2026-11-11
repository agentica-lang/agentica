#!/bin/sh
# macOS pipe_pair hang experiment (#1392, never merged). Usage: tools/exp-mac.sh MINUTES
# Round 1: pipe_pair-test alone in a loop. Round 2: four loops of it beside `make vm-test` in a loop (the load of CI,
# where the hangs happened). A hang ends after EXP_DEADLINE_MS with the watchdog's report and the EXP probe lines.
set -u
minutes=${1:-40}
test=build/vm/release/pipe_pair-test
out=build/exp-mac
mkdir -p $out
export EXP_DEADLINE_MS=10000

loop() { # NAME SECONDS: runs the test until SECONDS pass; counts passes and keeps each failure's output
  name=$1; end=$(( $(date +%s) + $2 )); pass=0; fail=0
  while [ "$(date +%s)" -lt $end ]; do
    if $test > $out/$name.last 2>&1; then pass=$((pass + 1)); else fail=$((fail + 1)); cp $out/$name.last $out/$name.fail.$fail; fi
  done
  echo "$name: passed=$pass failed=$fail"
}

half=$(( minutes * 30 ))
echo "round 1: alone for $half s"
loop alone $half

echo "round 2: four loops beside make vm-test for $half s"
for k in 1 2 3 4; do loop load$k $half > $out/load$k.summary & done
end=$(( $(date +%s) + half )); runs=0; failed=0
while [ "$(date +%s)" -lt $end ]; do
  runs=$((runs + 1))
  make vm-test JOBS=4 > $out/vmtest.last 2>&1 || { failed=$((failed + 1)); cp $out/vmtest.last $out/vmtest.fail.$failed; }
done
wait
cat $out/load*.summary
echo "make vm-test: runs=$runs failed=$failed"
for f in $out/*.fail.*; do [ -f "$f" ] || continue; echo "== $f"; grep -E "pipe pair test|EXP|C test failed|Assertion|COMMAND|pipe_pair|unix|->" "$f" | head -40; done
