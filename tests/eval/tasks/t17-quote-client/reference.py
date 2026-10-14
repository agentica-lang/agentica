import http.client
import json
import sys
import urllib.error
import urllib.request


def failure_text(body: str) -> str:
    try:
        parsed = json.loads(body)
    except ValueError:
        return "error: bad response"
    if not isinstance(parsed, dict) or not isinstance(parsed.get("error"), str):
        return "error: bad response"
    return f"error: {parsed['error']}"


def quote(base: str, item: str, quantity: int) -> str:
    body = json.dumps({"item": item, "quantity": quantity}).encode()
    request = urllib.request.Request(
        base + "/quote",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            status: int = response.status
            text: str = response.read().decode()
    except urllib.error.HTTPError as exc:
        status = exc.code
        text = exc.read().decode(errors="replace")
    except (urllib.error.URLError, http.client.HTTPException, OSError):
        return "error: no response"
    if status == 200:
        try:
            reply = json.loads(text)
            total = reply["total_cents"]
            if type(total) is not int or type(reply["unit_cents"]) is not int or not isinstance(reply["item"], str):
                return "error: bad response"
        except (ValueError, KeyError, TypeError):
            return "error: bad response"
        return f"{item}: {total}"
    if status in (400, 404):
        return failure_text(text)
    return "error: bad response"


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
