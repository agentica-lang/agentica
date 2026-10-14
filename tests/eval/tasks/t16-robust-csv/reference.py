import re
import sys
from dataclasses import dataclass


@dataclass(frozen=True)
class Dept:
    rows: int
    total: int
    top_name: str
    top_salary: int


@dataclass(frozen=True)
class Row:
    name: str
    dept: str
    salary: int


class RowError(Exception):
    pass


INTEGER = re.compile(r"[+-]?[0-9]+")


def add_row(dept: Dept, name: str, salary: int) -> Dept:
    if dept.rows == 0 or salary > dept.top_salary:
        return Dept(dept.rows + 1, dept.total + salary, name, salary)
    return Dept(dept.rows + 1, dept.total + salary, dept.top_name, dept.top_salary)


def parse_row(line: str) -> Row:
    fields = line.split(",")
    if len(fields) != 3:
        raise RowError(f"expected 3 fields, got {len(fields)}")
    name = fields[0].strip()
    dept = fields[1].strip()
    text = fields[2].strip()
    if name == "":
        raise RowError("empty name")
    if dept == "":
        raise RowError("empty department")
    if INTEGER.fullmatch(text) is None:
        raise RowError(f'bad salary "{text}"')
    salary = int(text)
    if salary < 0:
        raise RowError("negative salary")
    return Row(name, dept, salary)


def main() -> None:
    depts: dict[str, Dept] = {}
    empty = Dept(0, 0, "", 0)
    rejected = 0
    for number, raw in enumerate(sys.stdin, start=1):
        line = raw.strip()
        if number == 1 or line == "":
            continue
        try:
            row = parse_row(line)
        except RowError as exc:
            print(f"line {number}: {exc}")
            rejected += 1
            continue
        depts[row.dept] = add_row(depts.get(row.dept, empty), row.name, row.salary)
    if len(depts) == 0:
        print("no rows")
    for dept in sorted(depts):
        d = depts[dept]
        print(f"{dept}: {d.rows} rows, total {d.total}, average {d.total // d.rows}, top {d.top_name}")
    print(f"rejected: {rejected}")


if __name__ == "__main__":
    main()
