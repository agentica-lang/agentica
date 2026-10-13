#!/usr/bin/env bash
cd "$(dirname "$0")/.." || exit 1
xargs -d '\n' -P "$(nproc)" -I{} bash -c 'out=$({} 2>&1) || { echo "::error::failed: {}"; echo "$out"; exit 1; }' <<'LIST'
racket src/main.rkt --allow-run examples/process-tool.agc
racket src/main.rkt examples/dispatch.agc
racket src/main.rkt examples/concurrency.agc
racket src/main.rkt examples/hello.agc
racket src/main.rkt examples/classify.agc
racket src/main.rkt examples/tasks.agc
racket src/main.rkt examples/inventory.agc
racket src/main.rkt examples/strings.agc
racket src/main.rkt examples/result.agc
racket src/main.rkt examples/blocks.agc
racket src/main.rkt examples/json.agc
dist/agentica examples/json-modules.agc
dist/agentica check examples/json-modules.agc
dist/agentica examples/hello.agc
dist/agentica examples/tasks.agc
dist/agentica examples/file-summary.agc examples/hello.agc
dist/agentica --allow-run examples/process-tool.agc
diff <(dist/agentica --seed 7 tests/fixtures/vm/random.agc) <(dist/agentica --seed 7 tests/fixtures/vm/random.agc)
dist/agentica examples/queue.agc
dist/agentica examples/http_server.agc
LIST
