import sys
from dataclasses import dataclass


@dataclass(frozen=True)
class Dept:
    rows: int
    total: int
    top_name: str
    top_salary: int


def add_row(dept: Dept, name: str, salary: int) -> Dept:
    if dept.rows == 0 or salary > dept.top_salary:
        return Dept(dept.rows + 1, dept.total + salary, name, salary)
    return Dept(dept.rows + 1, dept.total + salary, dept.top_name, dept.top_salary)


def main() -> None:
    depts: dict[str, Dept] = {}
    empty = Dept(0, 0, "", 0)
    header = True
    for raw in sys.stdin:
        line = raw.strip()
        if header:
            header = False
            continue
        if line == "":
            continue
        fields = line.split(",")
        name = fields[0].strip()
        dept = fields[1].strip()
        salary = int(fields[2].strip())
        depts[dept] = add_row(depts.get(dept, empty), name, salary)
    if len(depts) == 0:
        print("no rows")
        return
    for dept in sorted(depts):
        d = depts[dept]
        print(f"{dept}: {d.rows} rows, total {d.total}, average {d.total // d.rows}, top {d.top_name}")


if __name__ == "__main__":
    main()
