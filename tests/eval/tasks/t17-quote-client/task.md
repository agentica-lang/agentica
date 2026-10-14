# Task: repair a client for a price service

`start.agc` (or `start.py` for Python) is a client for a small price service, and it does not work against the service. Fix it and save the result as `solution.agc` (or `solution.py`). The service address is given to the program as its first command-line argument, a base URL like `http://127.0.0.1:34567` (`System.args()[0]` in Agentica, `sys.argv[1]` in Python). The service is not available to you while you work: test the client against a small server of your own on `127.0.0.1`, which you can write in the same language.

## The program

It reads orders from standard input until EOF, one per line: `ITEM QTY` (single space; blank lines are ignored). For each order it asks the service for a quote and prints one line. A line that is not `ITEM QTY`, or whose `QTY` is not an integer of 1 or more, prints `error: bad order: <the line, trimmed>` and sends nothing. At the end it prints `orders: N, failed: F`, where `N` is the number of requests sent and `F` how many of them printed an error.

## The service

`POST {base}/quote` with the header `Content-Type: application/json` and a JSON body with exactly two fields: `{"item": "tea", "quantity": 3}` (`quantity` is an integer).

- `200`: the body is a JSON object with `item` (string), `unit_cents` (integer) and `total_cents` (integer), and possibly other fields. The client prints `ITEM: TOTAL_CENTS` with the value of `total_cents`, for example `tea: 750`.
- `400` and `404`: the body is `{"error": "<message>"}`. The client prints `ITEM: error: <message>`, for example `salt: error: unknown item`.
- Any other status, or a `200` whose body is not a JSON object with those three fields of the right types, or an error status whose body has no string `error`: the client prints `ITEM: error: bad response`.
- No response at all (the server closes the connection, or the request fails): the client prints `ITEM: error: no response`.

Every request is a separate order; the client goes on after an error. The exit code is 0 in all of these cases.

Example input:

```text
tea 3
salt 2
tea 0
```

Example output when the service knows `tea` (250 cents) and not `salt`:

```text
tea: 750
salt: error: unknown item
error: bad order: tea 0
orders: 2, failed: 1
```

Test it with your own input before you finish.
