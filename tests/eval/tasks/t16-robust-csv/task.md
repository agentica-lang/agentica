# Task: report bad rows instead of halting

`start.agc` (or `start.py` for Python) summarizes a CSV of salaries. The first line of the input is a header and is always skipped. Every later line is `name,department,salary`, with spaces allowed around each field; blank lines are ignored. For each department, sorted by name, it prints `DEPT: N rows, total T, average A, top NAME`, where the average drops the fraction and `NAME` is the person with the highest salary in the department (the first one when salaries are equal). With no rows it prints `no rows`.

The program halts on the first bad row (a missing field, a salary that is not a number), and the good rows are lost. Change it so bad rows are reported and skipped, and save the result as `solution.agc` (or `solution.py`). Keep the behavior for good rows as it is.

A row is good when all of this holds, checked in this order. There is no quoting: a comma always separates fields.

1. It has exactly 3 fields. Otherwise the problem is `expected 3 fields, got K`, where `K` is the number of fields found by splitting the line at every comma.
2. The name (trimmed) is not empty. Otherwise `empty name`.
3. The department (trimmed) is not empty. Otherwise `empty department`.
4. The salary (trimmed) is an integer: digits with an optional leading `-` or `+`. Otherwise `bad salary "TEXT"`, where `TEXT` is the trimmed salary field, between double quotes.
5. The salary is not negative. Otherwise `negative salary`.

For a bad row the program prints `line N: <problem>` at once, where `N` is the line number in the input (the header is line 1, and blank lines count), and the row is left out of the summary. The program goes on with the next line. After the department lines (or `no rows`) it prints `rejected: K`, the number of bad rows. It exits normally in every case.

Example input:

```text
name,dept,salary
ana, eng, 100
bob,eng,120
cy,ops
eli,ops,abc
fay,ops,-5
hal,ops,+30
```

Example output:

```text
line 4: expected 3 fields, got 2
line 5: bad salary "abc"
line 6: negative salary
eng: 2 rows, total 220, average 110, top bob
ops: 1 rows, total 30, average 30, top hal
rejected: 3
```

Test it with your own input before you finish, including empty input.
