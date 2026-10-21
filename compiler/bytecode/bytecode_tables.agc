## The constants of the format: the version, the limits, and the opcode numbers with the
## groups of opcodes that share an operand layout. tests/test_frontend_bytecode.py checks OPCODES against vm/value.h.
## The Agentica version of the header is not here: it is an input of the front end (Settings in link_env.agc,
## docs/future/35-self-hosting.md, 35.3).

## The largest value of a u16 operand, and of every count the VM reads as a u16.
export MAX_U16 = 65_535

## The format version of the .agcb header (docs/vm/03-ir-and-bytecode.md 4.6).
export FORMAT_VERSION = 6

## The deepest nesting of List and Map in a JSON field type the loader accepts.
export MAX_TYPE_DEPTH = 1024

## The number of each opcode, in the order of `agc_opcode` in vm/value.h.
export OPCODES = {
  "move": 0, "const": 1, "step": 2, "add-i": 3, "sub-i": 4, "mul-i": 5, "div-i": 6, "mod-i": 7, "neg-i": 8, "not": 9,
  "lt-i": 10, "le-i": 11, "eq": 12, "ne": 13, "jump": 14, "jump-if-false": 15, "jump-if-true": 16, "call": 17,
  "call-builtin": 18, "return": 19, "add-f": 20, "sub-f": 21, "mul-f": 22, "div-f": 23, "neg-f": 24, "lt-f": 25,
  "le-f": 26, "concat": 27, "to-text": 28, "inspect": 29, "list": 30, "list-len": 31, "list-get": 32, "struct": 33,
  "field": 34, "enum": 35, "is-variant": 36, "payload": 37, "same": 38, "tail-call": 39, "try": 40, "is-ok": 41,
  "result-value": 42, "map": 43, "map-get": 44, "call-value": 45, "closure": 46, "range": 47, "range-bounds": 48,
  "struct-with": 49, "global": 50, "global-set": 51, "try-step": 52,
}

## The opcodes written as their first two operands and a zero.
export PAIR_OPS = Set.new([
  "move", "neg-i", "neg-f", "not", "to-text", "inspect", "list-len", "try", "is-ok", "result-value", "range-bounds",
  "call-value", "try-step",
])

## The opcodes written as their first operand and two zeros.
export SINGLE_OPS = Set.new(["return"])

## The opcodes written as their first operand and a 32-bit index split into two u16 (low half first).
export WIDE_OPS = Set.new(["call", "tail-call", "closure", "global", "global-set"])

## The fewest operands an instruction of these opcodes must have for the writer to read them; the other opcodes are
## written with the operands they have.
export NEEDS = {
  "const": 1, "jump": 1, "return": 1, "jump-if-false": 2, "jump-if-true": 2, "call-builtin": 2, "struct-with": 3,
  "move": 2, "neg-i": 2, "neg-f": 2, "not": 2, "to-text": 2, "inspect": 2, "list-len": 2, "try": 2, "is-ok": 2,
  "result-value": 2, "range-bounds": 2, "call-value": 2, "call": 2, "tail-call": 2, "closure": 2, "global": 2,
  "global-set": 2, "try-step": 2,
}
