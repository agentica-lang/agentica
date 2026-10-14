import sys
from dataclasses import dataclass


@dataclass(frozen=True)
class Entry:
    student: str
    subject: str
    score: int


@dataclass(frozen=True)
class Totals:
    sum: int
    weight: int


def average(totals: Totals) -> int:
    return totals.sum // totals.weight


def add_score(totals: Totals, score: int, weight: int) -> Totals:
    return Totals(sum=totals.sum + score * weight, weight=totals.weight + weight)


def letter(avg: int) -> str:
    if avg >= 90:
        return "A"
    elif avg >= 80:
        return "B"
    elif avg >= 70:
        return "C"
    elif avg >= 60:
        return "D"
    return "F"


def main() -> None:
    entries: list[Entry] = []
    weights: dict[str, int] = {}
    for raw in sys.stdin:
        line = raw.strip()
        if line == "":
            continue
        parts = line.split(" ")
        if parts[0] == "weight":
            weights[parts[1]] = int(parts[2])
        else:
            entries.append(Entry(student=parts[0], subject=parts[1], score=int(parts[2])))
    if len(entries) == 0:
        print("no scores")
        return
    students: dict[str, Totals] = {}
    everyone = Totals(sum=0, weight=0)
    for entry in entries:
        w = weights.get(entry.subject, 1)
        current = students.get(entry.student, Totals(sum=0, weight=0))
        students[entry.student] = add_score(current, entry.score, w)
        everyone = add_score(everyone, entry.score, w)
    ranked = sorted(sorted(students), key=lambda name: -average(students[name]))
    for rank, name in enumerate(ranked, start=1):
        avg = average(students[name])
        print(f"{rank}. {name}: {avg} {letter(avg)}")
    print(f"class: {average(everyone)}")


if __name__ == "__main__":
    main()
