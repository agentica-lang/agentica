import sys
from collections import deque


def make_maze(width: int, height: int, seed: int) -> set[int]:
    cells = set()
    state = seed
    for square in range(width * height):
        state = (state * 1103515245 + 12345) % 2147483648
        if state // 65536 % 100 < 70 or square in (0, width * height - 1):
            cells.add(square)
    return cells


def neighbors(width: int, height: int, square: int) -> list[int]:
    x, y = square % width, square // width
    result = []
    if y > 0:
        result.append(square - width)
    if x + 1 < width:
        result.append(square + 1)
    if y + 1 < height:
        result.append(square + width)
    if x > 0:
        result.append(square - 1)
    return result


def shortest(cells: set[int], width: int, height: int, start: int, goal: int) -> int:
    queue = deque([start])
    previous: dict[int, int] = {}
    seen = {start}
    while queue:
        current = queue.popleft()
        if current == goal:
            length = 0
            while current != start:
                current = previous[current]
                length += 1
            return length
        for nxt in neighbors(width, height, current):
            if nxt in cells and nxt not in seen:
                seen.add(nxt)
                previous[nxt] = current
                queue.append(nxt)
    return -1


def main(scale: int) -> None:
    rounds = 4 * scale
    width = height = 40
    checksum = 0
    solved = 0
    for round_ in range(rounds):
        cells = make_maze(width, height, round_ + 1)
        distance = shortest(cells, width, height, 0, width * height - 1)
        if distance >= 0:
            solved += 1
        checksum = (checksum * 1000 + distance + 1) % 1000000007
    print(f"maze-bfs {rounds}: solved {solved}, checksum {checksum}")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 1)
