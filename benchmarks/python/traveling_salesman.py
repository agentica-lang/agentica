import sys


def search(distances: list[list[int]], visited: list[bool], path: list[int], cost: int,
           best: tuple[int, list[int]]) -> tuple[int, list[int]]:
    current = path[-1]
    if len(path) == len(distances):
        total = cost + distances[current][0]
        return (total, path + [0]) if total < best[0] else best
    for city in range(1, len(distances)):
        if not visited[city]:
            next_cost = cost + distances[current][city]
            if next_cost < best[0]:
                visited[city] = True
                path.append(city)
                best = search(distances, visited, path, next_cost, best)
                path.pop()
                visited[city] = False
    return best


def make_distances(count: int, seed: int) -> list[list[int]]:
    state = seed
    points = []
    for _ in range(count):
        state = (state * 1103515245 + 12345) % 2147483648
        x = state // 65536 % 1000
        state = (state * 1103515245 + 12345) % 2147483648
        points.append((x, state // 65536 % 1000))
    return [[abs(ax - bx) + abs(ay - by) for bx, by in points] for ax, ay in points]


def main(scale: int) -> None:
    cities = 9
    checksum = 0
    for round_ in range(scale):
        distances = make_distances(cities, round_ + 7)
        visited = [False] * cities
        visited[0] = True
        cost, route = search(distances, visited, [0], 0, (1000000000, []))
        print(f"round {round_}: cost {cost}, route {route}")
        checksum = (checksum * 31 + cost) % 1000000007
    print(f"traveling-salesman {scale}: checksum {checksum}")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 1)
