import json
import sys


def reject_constant(value: str) -> None:
    raise ValueError(value)


def as_int(value: object) -> int:
    if type(value) is not int or not -(2**63) <= value <= 2**63 - 1:
        raise ValueError("invalid integer")
    return value


def handle_request(text: str) -> dict[str, int]:
    root = json.loads(text, parse_constant=reject_constant)
    if type(root) is not dict or type(root["values"]) is not list:
        raise ValueError("invalid request")
    request_id = as_int(root["id"])
    values = root["values"]
    if root["op"] == "count":
        result = len(values)
    elif root["op"] == "sum":
        result = sum(as_int(value) for value in values)
    else:
        raise ValueError("invalid operation")
    return {"id": request_id, "result": result}


def main() -> None:
    for line in sys.stdin:
        reply: dict[str, int] | dict[str, str]
        try:
            reply = handle_request(line)
        except (ValueError, KeyError, TypeError):
            reply = {"error": "invalid request"}
        print(json.dumps(reply, ensure_ascii=False, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    main()
