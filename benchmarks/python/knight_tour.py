import sys

MOVES = [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)]


def destinations(size: int, square: int, visited: list[bool]) -> list[int]:
    result = []
    for dx, dy in MOVES:
        x = square % size + dx
        y = square // size + dy
        if 0 <= x < size and 0 <= y < size and not visited[y * size + x]:
            result.append(y * size + x)
    return result


def search(size: int, square: int, visited: list[bool], path: list[int]) -> bool:
    visited[square] = True
    path.append(square)
    if len(path) == size * size:
        return True
    candidates = destinations(size, square, visited)
    order = sorted(range(len(candidates)), key=lambda i: len(destinations(size, candidates[i], visited)))
    for index in order:
        if search(size, candidates[index], visited, path):
            return True
    visited[square] = False
    path.pop()
    return False


def main(scale: int) -> None:
    size = 8
    tours = 0
    checksum = 0
    for _ in range(scale):
        for start in range(0, size * size, 3):
            path: list[int] = []
            if search(size, start, [False] * (size * size), path):
                tours += 1
                for step, square in enumerate(path, 1):
                    checksum = (checksum * 31 + square * step) % 1000000007
    print(f"knight-tour {scale}: tours {tours}, checksum {checksum}")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 1)
