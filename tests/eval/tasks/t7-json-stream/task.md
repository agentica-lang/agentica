# Task: JSON-lines requests

Read standard input one line at a time until EOF. Each line is an independent
JSON request with `id` (a signed 64-bit integer), `op` (a string), and `values`
(an array). Ignore extra fields. A blank line is an invalid request.

- `sum`: every value must be a signed 64-bit integer. Return their sum; an empty
  array sums to zero. Test inputs keep all sums within signed 64-bit bounds.
  Booleans and decimal numbers such as `1.0` are not integers.
- `count`: return the array length. Elements may have any JSON type, including
  false, null, objects, and arrays.

For a valid request, print compact JSON `{"id":<id>,"result":<number>}`, with
fields in that order, on one line. If parsing, extraction, or validation fails,
or the operation is unknown, print exactly `{"error":"invalid request"}`.
Continue with the next input line after every error. Flush each response so a
peer need not close stdin to receive it. For repeated object keys, the last
value wins.

Input:

```json
{"id":1,"op":"sum","values":[2,-1,4]}
{"id":2,"op":"count","values":[false,null,"tea"]}
{"id":3,"op":"sum","values":[true]}
```

Output:

```json
{"id":1,"result":5}
{"id":2,"result":3}
{"error":"invalid request"}
```

Write `solution.agc` or `solution.py`, as instructed. Test it with your own
input before finishing.
