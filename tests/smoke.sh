#!/usr/bin/env bash
cd "$(dirname "$0")/.." || exit 1
xargs -d '\n' -P "$(nproc)" -I{} bash -c 'out=$({} 2>&1) || { echo "::error::failed: {}"; echo "$out"; exit 1; }' <<'LIST'
dist/agentica examples/process-tool.agc
dist/agentica examples/dispatch.agc
dist/agentica examples/concurrency.agc
dist/agentica examples/hello.agc
dist/agentica examples/classify.agc
dist/agentica examples/tasks.agc
dist/agentica examples/inventory.agc
dist/agentica examples/strings.agc
dist/agentica examples/result.agc
dist/agentica examples/blocks.agc
dist/agentica examples/json.agc
dist/agentica examples/json-modules.agc
dist/agentica check examples/json-modules.agc
dist/agentica examples/file-summary.agc examples/hello.agc
diff <(dist/agentica --seed 7 tests/fixtures/vm/random.agc) <(dist/agentica --seed 7 tests/fixtures/vm/random.agc)
dist/agentica examples/queue.agc
dist/agentica examples/http_server.agc
LIST
