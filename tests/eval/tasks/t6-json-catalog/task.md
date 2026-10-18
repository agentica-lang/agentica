# Task: filter a JSON catalog

Read one JSON object from all of standard input. It has a `minimum` field (a
nonnegative integer) and a `products` field (an array of objects). Each product
has a `name` (a string) and `stock` (a nonnegative integer). Extra fields are
ignored. Integers must fit signed 64-bit; booleans and decimal numbers such as
`3.0` are not integers.

For each product with `stock >= minimum`, print one compact JSON object on its
own line, with `name` first and `stock` second. Preserve array order, including
repeated names. A valid empty catalog or one without qualifying products prints
nothing.

Validate the entire input before printing any products. If JSON parsing, field
extraction, or validation fails anywhere, print exactly `{"error":"invalid
catalog"}` on one line and nothing else.

Input:

```json
{"minimum":3,"products":[{"name":"tea","stock":2},{"name":"coffee","stock":5}]}
```

Output:

```json
{"name":"coffee","stock":5}
```

Write `solution.agc` or `solution.py`, as instructed. Test it with your own
input before finishing.
