# Examples

Run an example with `dist/agentica examples/<name>.agc`. The [README](../README.md) shows how to build `dist/agentica`.

- [`hello.agc`](hello.agc): a minimal program.
- [`classify.agc`](classify.agc): functions, control flow, and `try` propagation.
- [`tasks.agc`](tasks.agc): structs, lists, and field access.
- [`inventory.agc`](inventory.agc): maps, methods and interpolation.
- [`strings.agc`](strings.agc): string methods in Ruby style.
- [`blocks.agc`](blocks.agc): blocks and closures (`xs.map do |x| ... end`).
- [`dispatch.agc`](dispatch.agc): function values and `.call`.
- [`echo.agc`](echo.agc): read stdin line by line until EOF.
- [`file-summary.agc`](file-summary.agc): read a file given as an argument.
- [`concurrency.agc`](concurrency.agc): lightweight tasks with `Task.spawn` and `Task.await`.
- [`process-tool.agc`](process-tool.agc): run another program; needs `--allow-run`, as in `dist/agentica --allow-run examples/process-tool.agc`.
- [`tcp_echo.agc`](tcp_echo.agc): a TCP echo: read a line from a socket and send it back.
- [`http_get.agc`](http_get.agc): an HTTP client with `import "std/http" as HTTP`.
- [`http_server.agc`](http_server.agc): an HTTP server with `std/http`; `http_server.agc serve` keeps serving and prints its port.
- [`queue.agc`](queue.agc): the embedded `std/queue` library.
- [`json-modules.agc`](json-modules.agc): a program split across files (it imports [`modules/json-tools.agc`](modules/json-tools.agc)).
- [`mcp/stdio.agc`](mcp/stdio.agc): a minimal MCP stdio server.
- [`result.agc`](result.agc): Result values, propagation, messages, and fallbacks.
- [`json.agc`](json.agc): JSON encoding, parsing, extraction, and `try`.
- [`json-config.agc`](json-config.agc): extract and validate a nested service config, then encode a typed struct.
- [`json-expenses.agc`](json-expenses.agc): aggregate a JSON array into a map of category totals; amounts are integer cents, negative for refunds.
- [`json-lines.agc`](json-lines.agc): one JSON record per line; recovers from invalid records and flushes each response.
- [`knight-tour.agc`](knight-tour.agc): an open knight tour by degree-ordered backtracking.
- [`traveling-salesman.agc`](traveling-salesman.agc): an optimal circuit through a small directed distance matrix.
- [`maze-bfs.agc`](maze-bfs.agc): a shortest maze path by breadth-first search.

## Input from stdin

Three JSON examples read one document or one line per record from stdin. The algorithm examples can run long, so give them `--max-steps`.

```sh
printf '%s\n' '{"service":{"name":"api","port":8080,"enabled":false}}' | dist/agentica examples/json-config.agc
printf '%s\n' '[{"category":"food","amount":1200},{"category":"food","amount":-200}]' | dist/agentica examples/json-expenses.agc
printf '%s\n' '{"name":"Ana","score":75,"active":true}' 'not json' | dist/agentica examples/json-lines.agc
printf '%s\n' '{"size":8,"start":0}' | dist/agentica --max-steps 5000000 examples/knight-tour.agc
printf '%s\n' '{"distances":[[0,10,15,20],[10,0,35,25],[15,35,0,30],[20,25,30,0]]}' | dist/agentica --max-steps 5000000 examples/traveling-salesman.agc
printf '%s\n' '{"grid":[".#.","..."],"start":0,"goal":2}' | dist/agentica --max-steps 5000000 examples/maze-bfs.agc
```

The JSON examples print compact JSON. Configs need a nonempty name and a port from 1 to 65535. Scores must be 0 to 100, and an active score of at least 60 passes. A failed extraction gives an error object, and `json-lines` goes on to the next record.

## Knight tour and traveling salesman

Both read one JSON document and print one JSON document.

- Knight tour: a square board of size 1 to 8, and a zero-based start square (`row * size + column`). It prints `{"found":true,"path":[...]}`, or `{"found":false,"path":[]}` after the search is exhausted. Tours are open: they do not return to the start.
- Traveling salesman: a complete directed square matrix of 1 to 8 cities, with a zero diagonal and integer costs from 0 to 1,000,000,000. It prints the optimal circuit as `{"cost":...,"route":[0,...,0]}`. One city gives `[0,0]` and cost zero.
- Both print `{"error":"invalid input"}` for an invalid document.

Searches can be expensive. A step-limit diagnostic does not mean there is no solution; raise `--max-steps` and run it again.

## Maze

The grid has 1 to 32 rows and columns. `.` is open, `#` is blocked, and only horizontal and vertical steps are allowed. The start and goal use `row * width + column` and must be open cells. It prints `{"found":true,"distance":...,"path":[...]}`, or `{"found":false,"distance":-1,"path":[]}` when the goal cannot be reached. Invalid input gives `{"error":"invalid input"}`.

The queue in `maze-bfs.agc` uses numeric keys and deletes consumed entries. `Map.delete` takes O(n) time, so the example shows the API, not a fast queue.
