import sys
from dataclasses import dataclass


class CalcError(Exception):
    pass


@dataclass(frozen=True)
class Num:
    value: int


@dataclass(frozen=True)
class Ident:
    name: str


@dataclass(frozen=True)
class Sym:
    char: str


Token = Num | Ident | Sym


@dataclass(frozen=True)
class Parsed:
    value: int
    pos: int


@dataclass(frozen=True)
class Outcome:
    env: dict[str, int]
    text: str


def is_digit(c: str) -> bool:
    return "0" <= c <= "9"


def is_letter(c: str) -> bool:
    return "a" <= c <= "z" or c == "_"


def tokenize(text: str) -> list[Token]:
    tokens: list[Token] = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == " ":
            i += 1
        elif c in "+-*/()=":
            tokens.append(Sym(c))
            i += 1
        elif is_digit(c):
            j = i
            while j < n and is_digit(text[j]):
                j += 1
            tokens.append(Num(int(text[i:j])))
            i = j
        elif is_letter(c):
            j = i
            while j < n and is_letter(text[j]):
                j += 1
            tokens.append(Ident(text[i:j]))
            i = j
        else:
            raise CalcError(f"bad character '{c}'")
    return tokens


def trunc_div(a: int, b: int) -> int:
    q = abs(a) // abs(b)
    return q if (a < 0) == (b < 0) else -q


def parse_atom(env: dict[str, int], tokens: list[Token], pos: int) -> Parsed:
    if pos >= len(tokens):
        raise CalcError("unexpected end of input")
    token = tokens[pos]
    if isinstance(token, Num):
        return Parsed(token.value, pos + 1)
    if isinstance(token, Ident):
        if token.name not in env:
            raise CalcError(f"unknown variable {token.name}")
        return Parsed(env[token.name], pos + 1)
    if token.char == "(":
        inner = parse_expr(env, tokens, pos + 1)
        if inner.pos >= len(tokens):
            raise CalcError("expected )")
        closing = tokens[inner.pos]
        if isinstance(closing, Sym) and closing.char == ")":
            return Parsed(inner.value, inner.pos + 1)
        raise CalcError("expected )")
    raise CalcError("unexpected token")


def parse_term(env: dict[str, int], tokens: list[Token], pos: int) -> Parsed:
    left = parse_atom(env, tokens, pos)
    value = left.value
    p = left.pos
    while p < len(tokens):
        token = tokens[p]
        if isinstance(token, Sym) and token.char == "*":
            right = parse_atom(env, tokens, p + 1)
            value = value * right.value
            p = right.pos
        elif isinstance(token, Sym) and token.char == "/":
            right = parse_atom(env, tokens, p + 1)
            if right.value == 0:
                raise CalcError("division by zero")
            value = trunc_div(value, right.value)
            p = right.pos
        else:
            break
    return Parsed(value, p)


def parse_expr(env: dict[str, int], tokens: list[Token], pos: int) -> Parsed:
    left = parse_term(env, tokens, pos)
    value = left.value
    p = left.pos
    while p < len(tokens):
        token = tokens[p]
        if isinstance(token, Sym) and token.char == "+":
            right = parse_term(env, tokens, p + 1)
            value = value + right.value
            p = right.pos
        elif isinstance(token, Sym) and token.char == "-":
            right = parse_term(env, tokens, p + 1)
            value = value - right.value
            p = right.pos
        else:
            break
    return Parsed(value, p)


def finish(env: dict[str, int], tokens: list[Token], start: int) -> Parsed:
    parsed = parse_expr(env, tokens, start)
    if parsed.pos < len(tokens):
        raise CalcError("unexpected token")
    return parsed


def is_assignment(tokens: list[Token]) -> bool:
    if len(tokens) < 2:
        return False
    first, second = tokens[0], tokens[1]
    return isinstance(first, Ident) and isinstance(second, Sym) and second.char == "="


def evaluate(env: dict[str, int], line: str) -> Outcome:
    tokens = tokenize(line)
    first = tokens[0] if tokens else None
    if isinstance(first, Ident) and is_assignment(tokens):
        parsed = finish(env, tokens, 2)
        return Outcome({**env, first.name: parsed.value}, f"{first.name} = {parsed.value}")
    parsed = finish(env, tokens, 0)
    return Outcome(env, str(parsed.value))


def main() -> None:
    env: dict[str, int] = {}
    for raw in sys.stdin:
        line = raw.strip()
        if line == "":
            continue
        try:
            outcome = evaluate(env, line)
        except CalcError as exc:
            print(f"error: {exc}")
        else:
            print(outcome.text)
            env = outcome.env


if __name__ == "__main__":
    main()
