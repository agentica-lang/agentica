"""`agentica refs` through the product CLI: the references to a name, or to the name at a position, in a checked program
linked from FILE and the PATH... of the command (docs/future/39-semantic-cli.md, 39.3 to 39.7). The cases read the JSON
form and assert kinds, spans, files, functions, the codes and the exit codes, never message text; one case reads the
text form."""
import json
import re

import pytest

from tests.agentica_test import cli, run, vm_environment
from tests.span_support import end, problem, start, where

MODELS = '''export LIMIT = 10

## A user.
export struct User
  name: String
  age: Int
end

export struct Pet
  name: String
end

export enum Shape
  Circle(Float)
  Square
end

export def make(name: String) -> User
  return User(name: name, age: 3)
end

export def unused() -> Int
  return LIMIT
end
'''

# The file asked about. It has no `main`. Positions are found by text with `where`, so a line added here does not move
# them. The names `i`, `note` and `count` are bound in more than one scope on purpose.
ORDERS = '''import Models from "models"
import {LIMIT, make as create} from "models"

export def total(user: Models.User) -> Int
  return user.age + LIMIT
end

def pet_name(pet: Models.Pet) -> String
  return pet.name
end

def tally(names: List[String]) -> Int
  count = 0
  for i in names
    count += 1
    puts(i)
  end
  for i in names
    puts(i)
  end
  if count > 1
    note = "many"
    puts(note)
  else
    note = "few"
    puts(note)
  end
  suffix = "!"
  loud = names.map do |name: String| name + suffix end
  return count + loud.size
end

def area(shape: Models.Shape) -> Float
  case shape
    Models.Shape.Circle(radius) -> return radius * radius
    Models.Shape.Square -> return 1.0
  end
end

def build() -> Models.User
  made = Models.make("a")
  copy = made.with(age: 5)
  other = create("b")
  piped = "c" |> Models.make()
  pet = Models.Pet(name: "p")
  shape = Models.Shape.Circle(2.0)
  total_of = &total
  return copy
end
'''

# A third file that reaches `models` twice: through its own import and through `orders`.
REPORT = '''import Models from "models"
import Orders from "orders"

def render(user: Models.User) -> Int
  return Orders.total(user) + user.age
end
'''


def refs(position, *words, cwd, stdin=None, style="--json"):
    file, (line, column) = position
    return run(cli() + [style, "refs", *words, f"{file}:{line}:{column}"], env=vm_environment(), cwd=cwd, stdin=stdin)


def answer(position, *words, cwd, stdin=None):
    result = refs(position, *words, cwd=cwd, stdin=stdin)
    assert (result.code, result.stderr) == (0, "")
    return json.loads(result.stdout)


def ask(*words, cwd, stdin=None, style="--json"):
    """`agentica refs WORDS...` as typed: a name or a position first, then the paths."""
    return run(cli() + [style, "refs", *words], env=vm_environment(), cwd=cwd, stdin=stdin)


def told(*words, cwd, stdin=None):
    result = ask(*words, cwd=cwd, stdin=stdin)
    assert (result.code, result.stderr) == (0, "")
    return json.loads(result.stdout)


def spot(file, source, needle, inside=0, nth=1):
    """The `FILE:LINE:COL` word of a position found by text."""
    line, column = where(source, needle, inside, nth)
    return f"{file}:{line}:{column}"


def places(report):
    """The references as (file, line, column, kind, function), in the order of the answer."""
    return [(found["span"]["file"], *start(found["span"]), found["kind"], found["function"])
            for found in report["references"]]


def the_set(report):
    """What an answer says about a name, without the question: the definition and the references."""
    return report["definition"], report["builtin"], report["references"]


@pytest.fixture
def program(tmp_path):
    for name, text in (("models.agc", MODELS), ("orders.agc", ORDERS), ("report.agc", REPORT)):
        (tmp_path / name).write_text(text, encoding="utf-8")
    return tmp_path


def test_a_function_has_its_calls_and_values_through_every_way_to_name_it(program):
    report = answer(("orders.agc", where(ORDERS, "Models.make", 8)), cwd=program)
    assert (report["version"], report["command"], report["builtin"], report["skipped"]) == (1, "refs", None, [])
    definition = report["definition"]
    assert (definition["kind"], definition["name"], definition["module"], definition["exported"]) == (
        "function", "make", "models.agc", True)
    assert definition["signature"] == "make(name: String) -> User"
    assert start(definition["name_span"]) == where(MODELS, "make(name")
    # The span is the whole declaration, `export` included, as `symbol` and `outline` give it.
    assert start(definition["span"]) == where(MODELS, "export def make")
    # Through the alias (`Models.make`), through a pipe and through a name imported `as create`; the definition is not
    # one of the references, and each reference is the name alone.
    line_a, col_a = where(ORDERS, "Models.make(", 7)
    assert places(report) == [
        ("orders.agc", line_a, col_a, "call", "build"),
        ("orders.agc", *where(ORDERS, "create(", 0), "call", "build"),
        ("orders.agc", *where(ORDERS, "Models.make()", 7), "call", "build"),
    ]
    assert end(report["references"][1]["span"]) == (where(ORDERS, "create(", 6))
    # A `&name` is a value; the reference is the name after the `&`.
    values = answer(("orders.agc", where(ORDERS, "&total", 2)), cwd=program)
    assert places(values) == [("orders.agc", *where(ORDERS, "&total", 1), "value", "build")]


def test_a_name_that_nothing_uses_has_an_empty_list_and_exit_0(program):
    report = answer(("models.agc", where(MODELS, "unused", 2)), cwd=program)
    assert (report["definition"]["kind"], report["definition"]["name"], report["references"]) == (
        "function", "unused", [])


def test_a_struct_is_found_in_annotations_and_constructions_of_every_linked_file(program):
    report = answer(("orders.agc", where(ORDERS, "Models.User", 8)), cwd=program)
    assert (report["definition"]["kind"], report["definition"]["name"]) == ("struct", "User")
    assert places(report) == [
        ("orders.agc", *where(ORDERS, "Models.User) -> Int", 7), "type", "total"),
        ("orders.agc", *where(ORDERS, "-> Models.User\n", 10), "type", "build"),
        ("models.agc", *where(MODELS, "-> User", 3), "type", "make"),
        ("models.agc", *where(MODELS, "return User(", 7), "construct", "make"),
    ]
    # From the declaration itself the answer has the same definition, and the references of the files that `models.agc`
    # links: a command sees the file it is asked about and what it imports, so the uses in `orders.agc` are not there.
    from_definition = answer(("models.agc", where(MODELS, "User\n", 0)), cwd=program)
    assert from_definition["definition"] == report["definition"]
    assert from_definition["references"] == [found for found in report["references"]
                                             if found["span"]["file"] == "models.agc"]


def test_fields_of_two_structs_with_one_name_do_not_mix(program):
    report = answer(("orders.agc", where(ORDERS, "user.age", 5)), cwd=program)
    definition = report["definition"]
    assert (definition["kind"], definition["struct"], definition["signature"]) == ("field", "User", "age: Int")
    assert places(report) == [
        ("orders.agc", *where(ORDERS, "user.age", 5), "read", "total"),
        ("orders.agc", *where(ORDERS, "with(age", 5), "construct", "build"),
        ("models.agc", *where(MODELS, "age: 3", 0), "construct", "make"),
    ]
    # From the field's own declaration the definition is the same, and the references are those of `models.agc`.
    own = answer(("models.agc", where(MODELS, "age: Int")), cwd=program)
    assert own["definition"] == report["definition"]
    assert places(own) == [("models.agc", *where(MODELS, "age: 3"), "construct", "make")]
    user_name = answer(("models.agc", where(MODELS, "name: String\n  age", 0)), cwd=program)
    pet_name = answer(("orders.agc", where(ORDERS, "pet.name", 4)), cwd=program)
    assert (user_name["definition"]["struct"], pet_name["definition"]["struct"]) == ("User", "Pet")
    assert places(pet_name) == [
        ("orders.agc", *where(ORDERS, "pet.name", 4), "read", "pet_name"),
        ("orders.agc", *where(ORDERS, "Pet(name", 4), "construct", "build"),
    ]
    # `name` of User is read nowhere and built in `make`; the `name:` arguments of Pet are not its.
    assert places(user_name) == [("models.agc", *where(MODELS, "name: name", 0), "construct", "make")]


def test_an_enum_and_its_variants_are_found_in_constructors_and_patterns(program):
    variant = answer(("orders.agc", where(ORDERS, "Models.Shape.Circle(radius)", 14)), cwd=program)
    assert (variant["definition"]["kind"], variant["definition"]["enum"], variant["definition"]["signature"]) == (
        "variant", "Shape", "Circle(Float)")
    assert places(variant) == [
        ("orders.agc", *where(ORDERS, "Models.Shape.Circle(radius)", 13), "pattern", "area"),
        ("orders.agc", *where(ORDERS, "Models.Shape.Circle(2.0)", 13), "construct", "build"),
    ]
    enum = answer(("orders.agc", where(ORDERS, "Models.Shape.Square", 8)), cwd=program)
    assert (enum["definition"]["kind"], enum["definition"]["name"]) == ("enum", "Shape")
    assert [(found[3], found[4]) for found in places(enum)] == [
        ("type", "area"), ("pattern", "area"), ("pattern", "area"), ("construct", "build")]
    # A position on the module alias of a constructor selects the enum, as one on the enum does.
    on_alias = answer(("orders.agc", where(ORDERS, "Models.Shape.Square", 1)), cwd=program)
    assert the_set(on_alias) == the_set(enum)


def test_a_constant_is_a_value_wherever_it_is_read(program):
    report = answer(("orders.agc", where(ORDERS, "+ LIMIT", 2)), cwd=program)
    assert (report["definition"]["kind"], report["definition"]["name"], report["definition"]["module"]) == (
        "constant", "LIMIT", "models.agc")
    assert places(report) == [
        ("orders.agc", *where(ORDERS, "+ LIMIT", 2), "value", "total"),
        ("models.agc", *where(MODELS, "return LIMIT", 7), "value", "unused"),
    ]


def test_sibling_scopes_keep_their_uses_apart(program):
    first = answer(("orders.agc", where(ORDERS, "for i in names", 4)), cwd=program)
    assert first["definition"]["kind"] == "loop"
    assert places(first) == [("orders.agc", *where(ORDERS, "puts(i)", 5), "binding", "tally")]
    second = answer(("orders.agc", where(ORDERS, "for i in names", 4, 2)), cwd=program)
    assert places(second) == [("orders.agc", *where(ORDERS, "puts(i)", 5, 2), "binding", "tally")]
    # `note` is bound in each branch of the `if`, and each use belongs to its own branch.
    many = answer(("orders.agc", where(ORDERS, 'note = "many"', 1)), cwd=program)
    assert (many["definition"]["kind"], start(many["definition"]["name_span"])) == (
        "local", where(ORDERS, 'note = "many"'))
    assert places(many) == [("orders.agc", *where(ORDERS, "puts(note)", 5, 1), "binding", "tally")]
    few = answer(("orders.agc", where(ORDERS, "puts(note)", 5, 2)), cwd=program)
    assert start(few["definition"]["name_span"]) == where(ORDERS, 'note = "few"')
    assert places(few) == [("orders.agc", *where(ORDERS, "puts(note)", 5, 2), "binding", "tally")]


def test_an_outer_binding_is_used_in_blocks_and_by_compound_assignment(program):
    count = answer(("orders.agc", where(ORDERS, "count = 0", 1)), cwd=program)
    assert places(count) == [
        ("orders.agc", *where(ORDERS, "count += 1", 0), "binding", "tally"),
        ("orders.agc", *where(ORDERS, "count > 1", 0), "binding", "tally"),
        ("orders.agc", *where(ORDERS, "count + loud", 0), "binding", "tally"),
    ]
    suffix = answer(("orders.agc", where(ORDERS, "name + suffix", 7)), cwd=program)
    assert suffix["definition"]["kind"] == "local"
    assert places(suffix) == [("orders.agc", *where(ORDERS, "name + suffix", 7), "binding", "tally")]
    block_param = answer(("orders.agc", where(ORDERS, "name + suffix", 1)), cwd=program)
    assert block_param["definition"]["kind"] == "parameter"
    assert places(block_param) == [("orders.agc", *where(ORDERS, "name + suffix", 0), "binding", "tally")]
    # A parameter and a name bound by a pattern.
    parameter = answer(("orders.agc", where(ORDERS, "user: Models.User", 1)), cwd=program)
    assert (parameter["definition"]["kind"], places(parameter)) == (
        "parameter", [("orders.agc", *where(ORDERS, "user.age", 0), "binding", "total")])
    radius = answer(("orders.agc", where(ORDERS, "radius * radius", 1)), cwd=program)
    assert radius["definition"]["kind"] == "pattern"
    assert [found[1:3] for found in places(radius)] == [where(ORDERS, "radius * radius", 0),
                                                         where(ORDERS, "radius * radius", 9)]


def test_a_builtin_has_no_definition_and_lists_its_calls_and_method_calls(program):
    puts = answer(("orders.agc", where(ORDERS, "puts(i)", 1)), cwd=program)
    assert (puts["definition"], puts["builtin"]) == (None, "puts")
    assert {found["kind"] for found in puts["references"]} == {"call"}
    assert len(puts["references"]) == 4
    mapped = answer(("orders.agc", where(ORDERS, "names.map", 7)), cwd=program)
    assert (mapped["builtin"], mapped["definition"]) == ("List.map", None)
    assert places(mapped) == [("orders.agc", *where(ORDERS, "names.map", 6), "call", "tally")]


def test_every_returned_span_asked_back_gives_the_same_answer_and_type_at_agrees(program):
    names = [
        ("orders.agc", where(ORDERS, "Models.make", 8)),
        ("orders.agc", where(ORDERS, "Models.User", 8)),
        ("orders.agc", where(ORDERS, "user.age", 5)),
        ("orders.agc", where(ORDERS, "Models.Shape.Circle(radius)", 14)),
        ("orders.agc", where(ORDERS, "Models.Shape.Square", 8)),
        ("orders.agc", where(ORDERS, "+ LIMIT", 2)),
        ("orders.agc", where(ORDERS, "count = 0", 1)),
        ("orders.agc", where(ORDERS, "for i in names", 4)),
    ]
    for position in names:
        report = answer(position, cwd=program)
        spans = [(found["span"]["file"], start(found["span"])) for found in report["references"]]
        spans.append((report["definition"]["name_span"]["file"], start(report["definition"]["name_span"])))
        # Only a span of the root file can be asked back: a command links the file it is asked about and its imports.
        for file, (line, column) in spans:
            if file == "orders.agc":
                again = answer((file, (line, column)), cwd=program)
                assert the_set(again) == the_set(report), (position, file, line, column)
    # `type-at` names the same definition at a use of a call, a read and a binding.
    for needle, inside in (("Models.make", 8), ("user.age", 5), ("puts(i)", 5)):
        position = ("orders.agc", where(ORDERS, needle, inside))
        reference = answer(position, cwd=program)
        file, (line, column) = position
        typed = run(cli() + ["--json", "type-at", f"{file}:{line}:{column}"], env=vm_environment(), cwd=program)
        assert typed.code == 0
        definition = json.loads(typed.stdout)["definition"]
        assert definition["name_span"] == reference["definition"]["name_span"]


def test_a_module_reached_twice_is_reported_once_and_the_root_comes_first(program):
    report = answer(("report.agc", where(REPORT, "user.age", 5)), cwd=program)
    assert (report["definition"]["kind"], report["definition"]["struct"]) == ("field", "User")
    files = [found[0] for found in places(report)]
    # The files in the order they were linked: the root, `models` (its first import) and `orders`, which also reaches
    # `models`; the field is not listed twice for it.
    assert files == ["report.agc", "models.agc", "orders.agc", "orders.agc"]
    assert len(set(places(report))) == len(places(report))


def test_text_form_is_the_definition_then_one_line_for_each_reference(program):
    position = where(ORDERS, "user.age", 5)
    result = run(cli() + ["refs", f"orders.agc:{position[0]}:{position[1]}"], env=vm_environment(), cwd=program)
    assert (result.code, result.stderr) == (0, "")
    age = where(MODELS, "age: Int")
    assert result.stdout.split("\n") == [
        f"models.agc:{age[0]}:{age[1]} definition field User.age: Int",
        f"orders.agc:{position[0]}:{position[1]} read in total",
        f"orders.agc:{where(ORDERS, 'with(age', 5)[0]}:{where(ORDERS, 'with(age', 5)[1]} construct in build",
        f"models.agc:{where(MODELS, 'age: 3')[0]}:{where(MODELS, 'age: 3')[1]} construct in make",
        "",
    ]
    nothing = run(cli() + ["refs", "models.agc:%d:%d" % where(MODELS, "unused", 2)], env=vm_environment(), cwd=program)
    assert nothing.stdout.split("\n")[1:] == [""]


def test_a_position_on_no_name_is_query_no_expression_at_the_position(program):
    cases = {
        "a blank": where(ORDERS, "user.age + LIMIT", 8),
        "a keyword": where(ORDERS, "return user"),
        "an import": where(ORDERS, "import Models", 8),
        "a literal": where(ORDERS, "count = 0", 8),
    }
    for label, (line, column) in cases.items():
        diagnostic = problem(refs(("orders.agc", (line, column)), cwd=program), "QUERY-NO-EXPRESSION", 2)
        assert diagnostic["file"] == "orders.agc", label
        assert diagnostic["range"]["start"] == {"line": line, "column": column}, label
    past = problem(refs(("orders.agc", (ORDERS.count("\n") + 40, 3)), cwd=program), "QUERY-NO-EXPRESSION", 2)
    assert past["range"]["start"] == past["range"]["end"]


def test_a_check_error_is_exit_1_with_its_code_and_a_mistake_in_the_words_is_query_usage(program):
    (program / "bad.agc").write_text('def f() -> Int\n  return "x"\nend\n', encoding="utf-8")
    assert problem(refs(("bad.agc", (2, 10)), cwd=program), "CHECK-TYPE-MISMATCH", 1)["file"] == "bad.agc"
    for words in ([], [""], ["orders.agc:3"], ["orders.agc:0:3"], ["orders.agc:3:4", "extra"], ["total", "absent"],
                  ["--stdin"], ["--unknown", "orders.agc:3:4"], ["absent.agc:1:1"], ["--stdin", "a.agc:1"]):
        result = run(cli() + ["--json", "refs", *words], env=vm_environment(), cwd=program, stdin="")
        diagnostic = problem(result, "QUERY-USAGE", 2)
        assert diagnostic["file"] == "<arguments>", words


def test_the_buffer_on_standard_input_wins_over_the_file_on_the_disk(program):
    buffer = "def double(n: Int) -> Int\n  return n * 2\nend\n"
    report = answer(("orders.agc", (2, 10)), "--stdin", cwd=program, stdin=buffer)
    assert (report["definition"]["kind"], places(report)) == ("parameter", [("orders.agc", 2, 10, "binding", "double")])
    assert (program / "orders.agc").read_text(encoding="utf-8") == ORDERS


def as_set(report):
    """The definition, the builtin and the references in a fixed order: the order of the references follows the files as
    they were linked, which depends on the file the question starts from."""
    ordered = sorted(report["references"], key=lambda found: (found["span"]["file"], start(found["span"])))
    return report["definition"], report["builtin"], ordered


def symbol_match(name, *paths, cwd):
    result = run(cli() + ["--json", "symbol", name, *paths], env=vm_environment(), cwd=cwd)
    assert (result.code, result.stderr) == (0, "")
    matches = json.loads(result.stdout)["matches"]
    assert len(matches) == 1, name
    return matches[0]


# A name, and a position of the same declaration: the file, the text to look for and how far into it.
DECLARATIONS = [
    ("Models.make", "orders.agc", ORDERS, "Models.make", 8),
    ("make", "orders.agc", ORDERS, "Models.make", 8),
    ("Models.User", "orders.agc", ORDERS, "Models.User", 8),
    ("User", "orders.agc", ORDERS, "Models.User", 8),
    ("User.age", "orders.agc", ORDERS, "user.age", 5),
    ("Models.User.age", "orders.agc", ORDERS, "user.age", 5),
    ("Pet.name", "orders.agc", ORDERS, "pet.name", 4),
    ("Models.Shape.Circle", "orders.agc", ORDERS, "Models.Shape.Circle(radius)", 14),
    ("Shape.Square", "orders.agc", ORDERS, "Models.Shape.Square", 14),
    ("Models.Shape", "orders.agc", ORDERS, "Models.Shape.Square", 8),
    ("LIMIT", "orders.agc", ORDERS, "+ LIMIT", 2),
    ("unused", "models.agc", MODELS, "unused", 2),
]


def test_a_name_selects_what_its_position_selects_and_the_definition_is_the_match_of_symbol(program):
    for name, file, source, needle, inside in DECLARATIONS:
        by_name = told(name, ".", cwd=program)
        by_position = told(spot(file, source, needle, inside), ".", cwd=program)
        assert as_set(by_name) == as_set(by_position), name
        assert by_name["query"] == name
        # The definition has the fields of a `symbol` match, `doc` and the type of a field or the payload of a variant
        # included, and is that match.
        assert by_name["definition"] == symbol_match(name, ".", cwd=program), name
    assert told("User", cwd=program)["definition"]["doc"] == "A user."
    age = told("User.age", cwd=program)["definition"]
    assert (age["struct"], age["type"], age["signature"]) == ("User", "Int", "age: Int")
    circle = told("Shape.Circle", cwd=program)["definition"]
    assert (circle["enum"], circle["payload"]) == ("Shape", ["Float"])
    # A local has the same fields; its kind is the binding's and it has no doc.
    local = answer(("orders.agc", where(ORDERS, "user: Models.User", 1)), cwd=program)["definition"]
    assert (local["kind"], local["doc"], local["exported"]) == ("parameter", None, False)
    assert set(local) == set(told("make", cwd=program)["definition"])


def test_a_name_lists_the_uses_in_every_file_of_the_paths_and_the_text_form_reads_like_the_position_form(program):
    report = told("Models.User.age", cwd=program)
    assert places(report) == [
        ("models.agc", *where(MODELS, "age: 3"), "construct", "make"),
        ("orders.agc", *where(ORDERS, "user.age", 5), "read", "total"),
        ("orders.agc", *where(ORDERS, "with(age", 5), "construct", "build"),
        ("report.agc", *where(REPORT, "user.age", 5), "read", "render"),
    ]
    text = ask("Models.User.age", cwd=program, style="--ai")
    assert (text.code, text.stderr) == (0, "")
    age = where(MODELS, "age: Int")
    assert text.stdout.split("\n")[0] == f"models.agc:{age[0]}:{age[1]} definition field User.age: Int"
    assert len(text.stdout.split("\n")) == 6


def test_paths_link_more_files_so_a_file_that_only_imports_the_target_is_seen(program):
    position = spot("models.agc", MODELS, "struct User", 7)
    alone = told(position, cwd=program)
    assert {found[0] for found in places(alone)} == {"models.agc"}
    # `orders.agc` imports `models.agc`; `report.agc` imports both.
    with_orders = told(position, "orders.agc", cwd=program)
    assert {found[0] for found in places(with_orders)} == {"models.agc", "orders.agc"}
    everything = told(position, ".", cwd=program)
    assert {found[0] for found in places(everything)} == {"models.agc", "orders.agc", "report.agc"}
    report_only = told(position, "report.agc", cwd=program)
    assert as_set(report_only) == as_set(everything)
    assert [found for found in places(everything) if found[0] == "report.agc"] == [
        ("report.agc", *where(REPORT, "Models.User", 7), "type", "render")]
    # The file of the position comes first, then the others in the order they were linked; a file is listed once.
    assert places(everything)[0][0] == "models.agc"
    from_orders = told(spot("orders.agc", ORDERS, "Models.User", 8), ".", cwd=program)
    assert [found[0] for found in places(from_orders)][:2] == ["orders.agc", "orders.agc"]
    assert len(set(places(everything))) == len(places(everything))
    assert (everything["skipped"], everything["builtin"]) == ([], None)


def test_with_paths_every_span_asked_back_gives_the_same_set(program):
    for name in ("Models.make", "Models.User", "User.age", "Shape.Circle", "Models.Shape", "LIMIT"):
        report = told(name, ".", cwd=program)
        spans = [found["span"] for found in report["references"]] + [report["definition"]["name_span"]]
        assert len(spans) > 2, name
        for span in spans:
            line, column = start(span)
            again = told(f"{span['file']}:{line}:{column}", ".", cwd=program)
            assert as_set(again) == as_set(report), (name, span["file"], line, column)


def test_a_path_that_does_not_link_is_skipped_and_the_file_of_the_position_must_link(program):
    (program / "broken.agc").write_text("export def broken(\n", encoding="utf-8")
    position = spot("models.agc", MODELS, "export def make", 11)
    for report in (told(position, ".", cwd=program), told("make", ".", cwd=program)):
        assert [(left["file"], left["diagnostic"]["code"]) for left in report["skipped"]] == [
            ("broken.agc", "LEX-UNCLOSED-DELIMITER")]
        assert report["definition"]["name"] == "make" and len(report["references"]) == 3
    text = ask("make", ".", cwd=program, style="--ai")
    assert (text.code, text.stderr.strip()) == (0, "skipped broken.agc: LEX-UNCLOSED-DELIMITER")
    # The file of the position is a root of its own: when it does not link there is nothing to ask about.
    broken = problem(ask("broken.agc:1:1", ".", cwd=program), "LEX-UNCLOSED-DELIMITER", 1)
    assert broken["file"] == "broken.agc"
    # So is a name when every file is left out.
    lonely = program / "lonely"
    lonely.mkdir()
    (lonely / "only.agc").write_text("export def only(\n", encoding="utf-8")
    assert problem(ask("only", "lonely", cwd=program), "LEX-UNCLOSED-DELIMITER", 1)["file"] == "lonely/only.agc"
    # A file that links but whose dependency does not is skipped with that file's diagnostic.
    (program / "needy.agc").write_text('import Gone from "./gone"\n\ndef needy() -> Int\n  return 1\nend\n',
                                       encoding="utf-8")
    report = told("make", ".", cwd=program)
    assert sorted((left["file"], left["diagnostic"]["code"]) for left in report["skipped"]) == [
        ("broken.agc", "LEX-UNCLOSED-DELIMITER"), ("lonely/only.agc", "LEX-UNCLOSED-DELIMITER"),
        ("needy.agc", "CHECK-IMPORT-IO")]


def test_a_name_that_nothing_declares_is_not_found_and_one_that_several_declarations_answer_to_is_ambiguous(tmp_path):
    for name, text in (("one.agc", "export def shared() -> Int\n  return 1\nend\n"),
                       ("two.agc", "export def shared() -> Int\n  return 2\nend\n"),
                       ("use_one.agc", 'import M from "one"\n\ndef a() -> Int\n  return M.shared()\nend\n'),
                       ("use_two.agc", 'import M from "two"\n\ndef b() -> Int\n  return M.shared()\nend\n')):
        (tmp_path / name).write_text(text, encoding="utf-8")
    missing = problem(ask("sharedd", cwd=tmp_path), "QUERY-NOT-FOUND", 2)
    assert missing["file"] == "<arguments>" and missing["help"]
    assert missing["range"] == {"start": {"line": 1, "column": 1}, "end": {"line": 1, "column": 1}}
    for name in ("shared", "M.shared"):
        ambiguous = problem(ask(name, cwd=tmp_path), "QUERY-AMBIGUOUS-NAME", 2)
        assert ambiguous["file"] == "<arguments>"
        assert ambiguous["range"] == {"start": {"line": 1, "column": 1}, "end": {"line": 1, "column": 1}}
        # The help names each candidate as FILE:LINE:COL, which is the position form.
        candidates = re.findall(r"[\w./]+:\d+:\d+", ambiguous["help"])
        assert candidates == ["one.agc:1:12", "two.agc:1:12"], name
        found = [told(candidate, ".", cwd=tmp_path) for candidate in candidates]
        assert [report["definition"]["module"] for report in found] == ["one.agc", "two.agc"]
        assert [[use["span"]["file"] for use in report["references"]] for report in found] == [
            ["use_one.agc"], ["use_two.agc"]]
    # The paths decide which declarations a name sees.
    assert told("M.shared", "one.agc", "use_one.agc", cwd=tmp_path)["definition"]["module"] == "one.agc"
    assert problem(ask("M.shared", "one.agc", "use_one.agc", "use_two.agc", cwd=tmp_path),
                   "QUERY-AMBIGUOUS-NAME", 2)
    # Two files that declare `main` do not mix: every module has its own prefix.
    (tmp_path / "a.agc").write_text("def main() -> Void\n  main()\nend\n", encoding="utf-8")
    (tmp_path / "b.agc").write_text('def main() -> Void\n  puts("b")\n  main()\nend\n', encoding="utf-8")
    mains = told("a.agc:1:6", "b.agc", cwd=tmp_path)
    assert places(mains) == [("a.agc", 2, 3, "call", "main")]
    assert places(told("b.agc:1:6", "a.agc", cwd=tmp_path)) == [("b.agc", 3, 3, "call", "main")]
    assert problem(ask("main", "a.agc", "b.agc", cwd=tmp_path), "QUERY-AMBIGUOUS-NAME", 2)


def test_a_builtin_is_found_by_name_with_no_definition(program):
    for name, needle, inside in (("puts", "puts(i)", 1), ("List.map", "names.map", 7)):
        by_name = told(name, "orders.agc", cwd=program)
        assert (by_name["definition"], by_name["builtin"]) == (None, name)
        assert as_set(by_name) == as_set(told(spot("orders.agc", ORDERS, needle, inside), cwd=program))
    nothing = told("File.read_text", ".", cwd=program)
    assert (nothing["definition"], nothing["builtin"], nothing["references"]) == (None, "File.read_text", [])
    assert problem(ask("Nope.read", ".", cwd=program), "QUERY-NOT-FOUND", 2)


def test_a_std_module_is_named_with_its_std_path_or_through_the_alias_of_a_file(program):
    (program / "queued.agc").write_text(
        'import Q from "std/queue"\n\ndef fresh() -> Int\n  q = Q.new()\n  return Q.size(q)\nend\n', encoding="utf-8")
    through_path = told("std/queue.new", "queued.agc", cwd=program)
    assert (through_path["definition"]["module"], through_path["definition"]["kind"]) == ("std/queue.agc", "function")
    assert ("queued.agc", 4, 9, "call", "fresh") in places(through_path)
    assert as_set(told("Q.new", "queued.agc", cwd=program)) == as_set(through_path)
    assert as_set(told("queued.agc:4:9", cwd=program)) == as_set(through_path)
    field = told("std/queue.QueueState.items", "queued.agc", cwd=program)
    assert (field["definition"]["kind"], field["definition"]["struct"]) == ("field", "QueueState")


def test_a_position_on_a_name_of_an_import_list_selects_the_imported_declaration(program):
    expected = told("make", ".", cwd=program)
    for needle, inside in (("make as create", 0), ("make as create", 3), ("create}", 2)):
        report = told(spot("orders.agc", ORDERS, needle, inside), cwd=program)
        assert as_set(report)[:2] == as_set(expected)[:2], (needle, inside)
        assert places(report)[0][0] == "orders.agc" or report["references"] == []
    constant = told(spot("orders.agc", ORDERS, "{LIMIT", 2), ".", cwd=program)
    assert as_set(constant) == as_set(told("LIMIT", ".", cwd=program))
    assert constant["definition"]["kind"] == "constant"
    # An alias names a module and the path is text: neither is a declaration.
    for needle, inside in (("Models from", 1), ('"models"', 2), ("from", 1), ("import", 2)):
        diagnostic = problem(refs(("orders.agc", where(ORDERS, needle, inside)), cwd=program), "QUERY-NO-EXPRESSION", 2)
        assert diagnostic["file"] == "orders.agc", needle


def test_a_check_error_of_a_path_is_exit_1_and_the_standard_input_stands_for_a_file_of_the_paths(program):
    (program / "bad.agc").write_text('def f() -> Int\n  return "x"\nend\n', encoding="utf-8")
    assert problem(ask("make", ".", cwd=program), "CHECK-TYPE-MISMATCH", 1)["file"] == "bad.agc"
    assert problem(ask(spot("models.agc", MODELS, "export def make", 11), "bad.agc", cwd=program),
                   "CHECK-TYPE-MISMATCH", 1)["file"] == "bad.agc"
    (program / "bad.agc").unlink()
    # A buffer for `models.agc`: it is searched first, the disk is not written.
    buffer = MODELS + "\nexport def fresh() -> Int\n  return 1\nend\n"
    report = told("fresh", "orders.agc", "--stdin", "models.agc", cwd=program, stdin=buffer)
    assert (report["definition"]["module"], report["definition"]["name"], report["references"]) == (
        "models.agc", "fresh", [])
    assert start(report["definition"]["name_span"]) == where(buffer, "fresh")
    by_position = told("--stdin", spot("orders.agc", ORDERS, "Models.make", 8), "models.agc", cwd=program,
                       stdin=ORDERS + "\ndef extra() -> Int\n  return total(Models.make(\"z\"))\nend\n")
    assert by_position["definition"]["name"] == "make"
    assert (program / "models.agc").read_text(encoding="utf-8") == MODELS


def test_a_main_of_a_root_keeps_its_signature_and_one_of_an_imported_file_is_not_checked(tmp_path):
    (tmp_path / "bad.agc").write_text('def main(x: Int) -> Void\n  puts("a")\nend\n', encoding="utf-8")
    (tmp_path / "other.agc").write_text("def other() -> Int\n  return 1\nend\n", encoding="utf-8")
    (tmp_path / "user.agc").write_text('import L from "lib"\n\ndef f() -> Int\n  return L.g()\nend\n', encoding="utf-8")
    (tmp_path / "lib.agc").write_text(
        "export def main(x: Int) -> Int\n  return x\nend\n\nexport def g() -> Int\n  return 1\nend\n", encoding="utf-8")
    # The root of a position, alone or with other roots, is checked as `type-at` checks it.
    for words in (["bad.agc:1:5"], ["bad.agc:1:5", "other.agc"], ["other.agc:1:5", "bad.agc"]):
        diagnostic = problem(ask(*words, cwd=tmp_path), "CHECK-MAIN", 1)
        assert (diagnostic["file"], diagnostic["range"]["start"]) == ("bad.agc", {"line": 1, "column": 1}), words
    assert told("user.agc:3:5", cwd=tmp_path)["definition"]["name"] == "f"


def test_a_file_name_is_not_found_with_a_hint_and_partial_goes_with_a_position_alone(program):
    hinted = problem(ask("models.agc", cwd=program), "QUERY-NOT-FOUND", 2)
    assert "models.agc:LINE:COL" in hinted["help"]
    for words in (["total", "--partial"], [spot("orders.agc", ORDERS, "total"), "models.agc", "--partial"]):
        assert problem(ask(*words, cwd=program), "QUERY-USAGE", 2)["file"] == "<arguments>", words


# A resource is found by its definition, through the alias of another file and in the result of its block, where the
# parser wraps it in Result.
def test_a_resource_is_found_in_the_signatures_of_its_block_and_of_another_file(tmp_path):
    db = ('extern "libdb.so"\n  export resource Db, free: db_close\n'
          "  export def db_open(path: C.String) -> Db\nend\n")
    use = 'import Raw from "db"\n\nexport def count(db: Raw.Db) -> Int\n  return 0\nend\n'
    (tmp_path / "db.agc").write_text(db, encoding="utf-8")
    (tmp_path / "use.agc").write_text(use, encoding="utf-8")
    for words in (["Raw.Db", "use.agc"], [spot("db.agc", db, "Db,"), "."]):
        report = told(*words, cwd=tmp_path)
        definition = report["definition"]
        assert (definition["kind"], definition["name"], definition["module"]) == ("resource", "Db", "db.agc"), words
        assert start(definition["name_span"]) == where(db, "Db,"), words
        assert sorted(places(report)) == [
            ("db.agc", *where(db, "Db\nend"), "type", "db_open"),
            ("use.agc", *where(use, "Db)"), "type", "count"),
        ], words


# An extern function with an out parameter has a record (Sqlite3Open) declared at the function's name: a question at
# the name or at a call is about the function, and a field of the record is defined at its out parameter.
NATIVE = '''extern "libsqlite3.so.0"
  resource Db, free: sqlite3_close_v2
  def sqlite3_open(filename: C.String, out db: Db) -> C.Int
end

def main() -> Void
  opened = sqlite3_open(":memory:")
  Native.close(opened.db)
end
'''


def test_an_extern_function_with_an_out_parameter_is_found_at_its_name_and_calls(tmp_path):
    (tmp_path / "native.agc").write_text(NATIVE, encoding="utf-8")
    call = ("native.agc", where(NATIVE, "sqlite3_open(\":", 0))
    for position in (call, ("native.agc", where(NATIVE, "sqlite3_open(filename", 0))):
        report = answer(position, cwd=tmp_path)
        definition = report["definition"]
        assert (definition["kind"], definition["name"]) == ("function", "sqlite3_open")
        assert start(definition["name_span"]) == where(NATIVE, "sqlite3_open(filename", 0)
        assert places(report) == [("native.agc", *call[1], "call", "main")]
    typed = run(cli() + ["--json", "type-at", "native.agc:%d:%d" % call[1]], env=vm_environment(), cwd=tmp_path)
    found = json.loads(typed.stdout)
    assert (typed.code, found["type"], found["definition"]["kind"]) == (0, "Sqlite3Open", "function")
    field = answer(("native.agc", where(NATIVE, "opened.db", 7)), cwd=tmp_path)
    assert (field["definition"]["kind"], field["definition"]["struct"], field["definition"]["signature"]) == (
        "field", "Sqlite3Open", "db: Db")
    assert start(field["definition"]["name_span"]) == where(NATIVE, "db: Db", 0)
    assert places(field) == [("native.agc", *where(NATIVE, "opened.db", 7), "read", "main")]
