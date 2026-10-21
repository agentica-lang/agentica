"""`agentica refs` through the product CLI: the references to the name at a position of a checked program
(docs/future/39-semantic-cli.md, 39.3 to 39.7). The cases read the JSON form and assert kinds, spans, files, functions,
the codes and the exit codes, never message text; one case reads the text form."""
import json

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
    assert start(definition["span"]) == where(MODELS, "def make")
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
    for words in ([], ["orders.agc"], ["orders.agc:3"], ["orders.agc:0:3"], ["orders.agc:3:4", "extra"],
                  ["--stdin"], ["--unknown", "orders.agc:3:4"], ["absent.agc:1:1"], ["total"]):
        result = run(cli() + ["--json", "refs", *words], env=vm_environment(), cwd=program, stdin="")
        diagnostic = problem(result, "QUERY-USAGE", 2)
        assert diagnostic["file"] == "<arguments>", words


def test_the_buffer_on_standard_input_wins_over_the_file_on_the_disk(program):
    buffer = "def double(n: Int) -> Int\n  return n * 2\nend\n"
    report = answer(("orders.agc", (2, 10)), "--stdin", cwd=program, stdin=buffer)
    assert (report["definition"]["kind"], places(report)) == ("parameter", [("orders.agc", 2, 10, "binding", "double")])
    assert (program / "orders.agc").read_text(encoding="utf-8") == ORDERS
