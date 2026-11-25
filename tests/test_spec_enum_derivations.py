"""Enum derivations, through `agentica --json check`: `Color.values` lists the variants of an enum whose variants have
no payload, `Color.parse(text)` reads one from its name, and `color.name` is the bare name of the variant of any enum
value. Each case asserts the code and the source text its range covers, never the message. What runs is the VM golden
tests/fixtures/vm/enum-derivations.agc; the chunked list of a big enum is run here.
"""

from tests.agentica_test import cli, run
from tests.spec_support import Batch, assert_rule

BATCH = Batch("main.agc")
table = BATCH.table
checked = BATCH.fixture()

HEAD = """enum Color
  Red
  Green
end

enum Shape
  Dot
  Circle(Int)
end

enum Tagged[T]
  Plain
  Boxed(T)
end

struct Person
  name: String
end

type Hue = Color

def main() -> Void
%s
end
"""

VALID = [
    "  all: List[Color] = Color.values\n  puts(all)",
    '  parsed: Result[Color] = Color.parse("Red")\n  puts(parsed)',
    "  puts(Color.Red.name)\n  puts(Shape.Circle(1).name)",
    '  puts(Person(name: "a").name)',
    '  puts(Color.parse("Red").unwrap!.name.size)',
    '  maybe: Optional[Color] = some(Color.Red)\n  puts(maybe&.name)',
    "  puts(Color.values.map do |color| color.name end)",
    '  puts(Color.parse(text: "Red"))',
    '  puts(System.Signal.values.size)\n  puts(System.Signal.parse("Hup"))',
]


@table("body", VALID, HEAD)
def test_values_parse_and_name_check(checked, body):
    assert checked(HEAD % body) is None


REJECTED = [
    # values and parse are for an enum without payloads and type parameters: any other type is refused.
    ("  puts(Person.values)", "CHECK-UNKNOWN-METHOD", "Person.values"),
    ("  puts(Shape.values)", "CHECK-UNKNOWN-METHOD", "Shape.values"),
    ("  puts(Tagged.values)", "CHECK-UNKNOWN-METHOD", "Tagged.values"),
    ('  puts(Shape.parse("Dot"))', "CHECK-UNKNOWN-METHOD", 'Shape.parse("Dot")'),
    ('  puts(Person.parse("a"))', "CHECK-UNKNOWN-METHOD", 'Person.parse("a")'),
    ("  puts(Hue.values)", "CHECK-UNKNOWN-TYPE", "Hue.values"),
    ('  puts(Hue.parse("Red"))', "CHECK-UNKNOWN-TYPE", 'Hue.parse("Red")'),
    # values has no parentheses, as members has; parse is not piped.
    ("  puts(Color.values())", "CHECK-UNKNOWN-NAME", "Color.values()"),
    ('  puts("Red" |> Color.parse())', "CHECK-UNKNOWN-NAME", "Color.parse()"),
    # parse takes one String.
    ("  puts(Color.parse())", "CHECK-ARITY", "Color.parse()"),
    ('  puts(Color.parse("Red", "Green"))', "CHECK-ARITY", 'Color.parse("Red", "Green")'),
    ("  puts(Color.parse(1))", "CHECK-TYPE-MISMATCH", "1"),
    ('  puts(Color.parse(name: "Red"))', "CHECK-UNKNOWN-ARGUMENT", 'name: "Red"'),
    ('  puts(Color.parse("Red", text: "Red"))', "CHECK-ARITY", 'Color.parse("Red", text: "Red")'),
    # A builtin enum with a payload has no values; the written form of parse is in the help.
    ("  puts(JSON.Node.values)", "CHECK-UNKNOWN-NAME", "JSON.Node.values"),
    ('  puts(System.Signal.parse(1))', "CHECK-TYPE-MISMATCH", "1"),
    # name is for an enum value, takes nothing, and is no field.
    ("  puts(Color.Red.name(1))", "CHECK-ARITY", "Color.Red.name(1)"),
    ("  puts(Color.Red.nme)", "CHECK-UNKNOWN-METHOD", "Color.Red.nme"),
    ("  puts(1.name)", "CHECK-UNKNOWN-METHOD", "1.name"),
    ('  puts(Person(name: "a").nme)', "CHECK-UNKNOWN-FIELD", 'Person(name: "a").nme'),
]


@table("body, code, text", REJECTED, HEAD)
def test_values_parse_and_name_refuse_what_is_not_an_enum_with_values(checked, body, code, text):
    program = HEAD % body
    assert_rule(checked(program), program, code, text)


MODELS = "enum Level\n  Low\n  High\nend\n"
BY_NAME = 'import {Level} from "models"\n\ndef main() -> Void\n  puts(Level.values.size)\n  puts(Level.parse("Low"))\nend\n'
BY_ALIAS = (
    'import Models from "models"\n\ndef main() -> Void\n  puts(Models.Level.values.size)\n'
    '  puts(Models.Level.parse("Low"))\nend\n'
)
MISSING = 'import Models from "models"\n\ndef main() -> Void\n  puts(Models.Level.parse(7))\nend\n'


@table("root, code, text", [(BY_NAME, None, None), (BY_ALIAS, None, None), (MISSING, "CHECK-TYPE-MISMATCH", "7")],
       lambda root, *_: {"main.agc": root, "models.agc": MODELS})
def test_values_and_parse_read_an_enum_imported_by_name_or_through_an_alias(checked, root, code, text):
    assert_rule(checked({"main.agc": root, "models.agc": MODELS}), root, code, text)


def test_values_of_an_enum_past_the_chunk_size_keeps_every_variant_in_order(tmp_path):
    # One `list` instruction gathers 255 items, so 300 variants need a second chunk joined with List.concat.
    variants = "".join("  V%d\n" % number for number in range(300))
    text = (
        "enum Wide\n%send\n\n"
        "def main() -> Void\n"
        "  all = Wide.values\n"
        "  puts(all.size)\n"
        "  puts(all[0].name)\n"
        "  puts(all[299].name)\n"
        '  puts(Wide.parse("V256").unwrap!.name)\n'
        "end\n\n"
    ) % variants
    path = tmp_path / "wide.agc"
    path.write_text(text, encoding="utf-8")
    result = run(cli() + [str(path)])
    assert (result.code, result.stdout.splitlines()) == (0, ["300", "V0", "V299", "V256"]), result.stderr
