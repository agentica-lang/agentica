# Task: find the slow server errors in a big log

Write a program that reads a request log and prints the server errors that were slow. The path of the log file is the first command-line argument (`System.args()[0]` in Agentica, `sys.argv[1]` in Python). Save the program as `solution.agc` (or `solution.py`).

The log is large: the tests use files from a few KB up to about 30 MB, with about 600,000 lines, and a few lines are several thousand characters long. A run has about 50 seconds. The input is the file only; nothing is read from standard input.

## The log

A text file in UTF-8, one request per line, with the fields `SEQ SERVICE METHOD PATH STATUS LATENCY_MS`. A line is split at every single space, and it is valid only when that gives exactly 6 fields (so a double space, a trailing space, or a missing field makes a line invalid), `SEQ`, `STATUS` and `LATENCY_MS` are made of digits only (at least one), and `SERVICE`, `METHOD` and `PATH` are not empty. Lines end with `\n`; some end with `\r\n`, and the last line may have no end of line. Blank lines and invalid lines are ignored without a message.

## The output

For every valid line with `STATUS` of 500 or more and `LATENCY_MS` of 800 or more, print one line `SEQ SERVICE LATENCY_MS` (the fields as they are written in the file), in the order of the file. Print nothing else on standard output. The exit code is 0 when the file was read.

Example log:

```text
1 auth GET /v1/users/7 500 800
2 auth GET /v1/users/7 500 799
3 cart POST /v1/orders/9 200 5000
4 cart POST /v1/orders/9 503 12000
bad line
```

Example output:

```text
1 auth 800
4 cart 12000
```

Test it with a log you generate yourself, also a big one, before you finish.
