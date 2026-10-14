import json
import sys
import urllib.request


def quote(base: str, item: str, quantity: int) -> str:
    body = json.dumps({"name": item, "qty": quantity}).encode()
    request = urllib.request.Request(
        base + "/quotes",
        data=body,
        headers={"Content-Type": "text/plain"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        reply = json.loads(response.read().decode())
    return f"{item}: {reply['total']}"


def main() -> None:
    base = sys.argv[1]
    sent = 0
    failed = 0
    for raw in sys.stdin:
        line = raw.strip()
        if line == "":
            continue
        parts = line.split(" ")
        try:
            quantity = int(parts[-1])
        except ValueError:
            quantity = 0
        if len(parts) != 2 or quantity < 1:
            print(f"error: bad order: {line}")
            continue
        text = quote(base, parts[0], quantity)
        sent += 1
        if text.startswith("error:"):
            failed += 1
            print(f"{parts[0]}: {text}")
        else:
            print(text)
    print(f"orders: {sent}, failed: {failed}")


if __name__ == "__main__":
    main()
