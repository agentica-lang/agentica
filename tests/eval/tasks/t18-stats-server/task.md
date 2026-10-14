# Task: repair a JSON service

`start.agc` (or `start.py` for Python) is a small HTTP service for numbers, and it does not meet its spec. Fix it and save the result as `solution.agc` (or `solution.py`). In Agentica use `std/http` (`import "std/http" as HTTP`); in Python use the standard library (`http.server`).

## How the service starts

It listens on `127.0.0.1` with a port the system picks (port 0). Once it is listening it prints one line, `listening PORT`, with the real port, and flushes it. Then it serves requests until it is killed. It reads nothing from standard input.

## The routes

Every response has the header `Content-Type: application/json` and a JSON object as its body.

- `GET /health`: `200` with `{"status":"ok"}`.
- `POST /stats`: the request body is JSON, `{"values":[...]}`. If `values` is a non-empty array of integers (not booleans, not decimal numbers), the answer is `200` with `{"count":N,"sum":S,"min":A,"max":B}` (the number of values, their sum, the smallest and the largest). If the body is not valid JSON the answer is `400` with `{"error":"invalid json"}`. If it is valid JSON but `values` is missing, not an array, empty, or holds anything but integers, the answer is `400` with `{"error":"values must be a non-empty array of integers"}`.
- `GET /double/N`: when `N` is an integer (digits, with an optional leading `-`), `200` with `{"n":N,"double":2N}`. Otherwise (also an empty `N`) `400` with `{"error":"not an integer"}`.
- `GET /hello`: `200` with `{"greeting":"hello, NAME"}`. `NAME` is the value of the first `name` parameter of the query string (`/hello?name=Ana`), which holds only letters and digits. Without a `name` parameter, or with an empty one, `NAME` is `world`. Other parameters are ignored.
- A path that is not one of these: `404` with `{"error":"not found"}`, for every method.
- One of these paths with the wrong method (`POST /health`, `GET /stats`, `PUT /double/3`, ...): `405` with `{"error":"method not allowed"}` and an `Allow` header that names the one method the path accepts (`GET` or `POST`).

The server must keep serving after any bad request. The query string is never part of the path: `/hello?name=Ana` is the path `/hello`.

Example, with the service on port 40001:

```text
GET /health          ->  200  {"status":"ok"}
POST /stats          ->  400  {"error":"invalid json"}      (body: not json)
GET /double/-4       ->  200  {"n":-4,"double":-8}
DELETE /nope         ->  404  {"error":"not found"}
```

Test it against your own client before you finish (a few requests with `curl`, if it is installed, or a short script).
