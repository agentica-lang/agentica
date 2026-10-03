import json
import sys


def reject_constant(value: str) -> None:
    raise ValueError(value)


def nonnegative_int(value: object) -> int:
    if type(value) is not int or not 0 <= value <= 2**63 - 1:
        raise ValueError("invalid integer")
    return value


def filter_catalog(text: str) -> str:
    root = json.loads(text, parse_constant=reject_constant)
    if type(root) is not dict or type(root["products"]) is not list:
        raise ValueError("invalid catalog")
    minimum = nonnegative_int(root["minimum"])
    output: list[str] = []
    for product in root["products"]:
        if type(product) is not dict or type(product["name"]) is not str:
            raise ValueError("invalid product")
        stock = nonnegative_int(product["stock"])
        if stock >= minimum:
            output.append(json.dumps(
                {"name": product["name"], "stock": stock},
                ensure_ascii=False,
                separators=(",", ":"),
            ) + "\n")
    return "".join(output)


def main() -> None:
    try:
        output = filter_catalog(sys.stdin.read())
    except (ValueError, KeyError, TypeError):
        output = '{"error":"invalid catalog"}\n'
    sys.stdout.write(output)


if __name__ == "__main__":
    main()
