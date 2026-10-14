import sys
from dataclasses import dataclass


@dataclass(frozen=True)
class Totals:
    sum: int
    count: int


def average(totals: Totals) -> int:
    return totals.sum // totals.count


def add_score(totals: Totals, score: int) -> Totals:
    return Totals(sum=totals.sum + score, count=totals.count + 1)


def main() -> None:
    students: dict[str, Totals] = {}
    everyone = Totals(sum=0, count=0)
    for raw in sys.stdin:
        line = raw.strip()
        if line == "":
            continue
        parts = line.split(" ")
        name = parts[0]
        score = int(parts[2])
        current = students.get(name, Totals(sum=0, count=0))
        students[name] = add_score(current, score)
        everyone = add_score(everyone, score)
    if everyone.count == 0:
        print("no scores")
        return
    for name in sorted(students):
        print(f"{name}: {average(students[name])}")
    print(f"class: {average(everyone)}")


if __name__ == "__main__":
    main()
