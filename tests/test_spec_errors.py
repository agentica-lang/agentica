"""The builtin Error record (#671), through `agentica --json check`: a failed Result holds an Error, which the pattern
`error(e)` binds and `error(...)` builds from a String or passes on. Each case asserts the code and the source text its
range covers, never the message. What the forms print is the VM golden tests/fixtures/vm/error-record.agc.
"""

import pytest

from tests.spec_support import Batch, assert_rule, check_diagnostic

BATCH = Batch("main.agc")
table = BATCH.table
checked = BATCH.fixture()

HEAD = """def parse(text: String) -> Result[Int]
  return error("empty") if text == ""

  text.to_i
end

def shout(text: String) -> String = text.upcase

def main() -> Void
  r = parse("")
%s
end
"""

VALID = [
    # The fields and their types, and the forms that read an Error as its text.
    "  case r\n    ok(n) -> puts(n)\n    error(e) ->\n      kind: String = e.kind\n      code: Optional[Int] = e.code\n"
    "      details: Map[String, String] = e.details\n      cause: Optional[Error] = e.cause\n"
    "      where: String = e.location\n      puts(\"#{kind} #{code} #{details} #{cause} #{where}\")\n  end",
    "  case r\n    ok(n) -> puts(n)\n    error(e) ->\n      puts(e)\n      puts(\"failed: #{e}\")\n"
    "      puts(e.to_s + e.inspect + e.message)\n  end",
    # A guard on the fields, and with to change one.
    "  case r\n    ok(n) -> puts(n)\n    error(e) if e.message == \"empty\" and e.code == none -> puts(e.with(kind: \"input\"))\n"
    "    error(_) -> puts(\"other\")\n  end",
    # error(e) passes the Error on as a Result of another type; Result.Err is the same call.
    "  s: Result[String] = case r\n    ok(n) -> ok(\"#{n}\")\n    error(e) -> error(e)\n  end\n  puts(s)",
    "  case r\n    ok(n) -> puts(n)\n    error(e) ->\n      b: Result[Bool] = Result.Err(e)\n      puts(b)\n  end",
    # An Error is a value: a list item, a parameter, JSON.
    "  case r\n    ok(n) -> puts(n)\n    error(e) ->\n      errors: List[Error] = [e]\n      puts(JSON.encode(errors[0]))\n"
    "      puts(JSON.decode(\"{}\", Error).ok?)\n  end",
]


def uses_r(body):
    """The body, with a read of r when it has none."""
    return body if "case r" in body else body + "\n  puts(r)"


KINDS = [
    # error(...) takes the fields of an Error as named arguments, in any order; code and cause are stored as some(...).
    "  e: Result[Int] = error(\"unique failed\", kind: \"db.constraint\", code: 19)\n  puts(e)",
    "  case r\n    ok(n) -> puts(n)\n    error(e) ->\n      w: Result[Int] = error(\"cannot load\", cause: e, kind: \"config\",\n"
    "        details: {\"line\": \"12\"})\n      puts(w)\n  end",
    "  w: Result[Int] = Result.Err(\"x\", kind: \"io.not_found_2\")\n  puts(w)",
    "  case r\n    ok(n) -> puts(n)\n    error(e) if e.is_a?(\"db\") or e.kind_of?(\"db.constraint\") -> puts(e)\n"
    "    error(e) -> puts(e.is_a?(e.kind))\n  end",
    # A pipe passes the message: "x" |> error(kind: ...) is error("x", kind: ...).
    "  w: Result[Int] = \"x\" |> error(kind: \"db.x\", code: 1)\n  puts(w)",
    # A computed kind is not checked, nor one set with .with.
    "  name = \"Not A Kind\"\n  w: Result[Int] = error(\"x\", kind: name)\n  puts(w)",
]


KINDS = [uses_r(body) for body in KINDS]


@table("body", KINDS, HEAD)
def test_error_takes_the_fields_of_an_error_as_named_arguments(checked, body):
    assert checked(HEAD % body) is None


KINDS_REJECTED = [
    ("  w: Result[Int] = error(\"x\", kind: \"Db Constraint\")\n  puts(w)", "CHECK-ERROR-KIND", "\"Db Constraint\""),
    ("  w: Result[Int] = error(\"x\", kind: \"\")\n  puts(w)", "CHECK-ERROR-KIND", "\"\""),
    ("  w: Result[Int] = error(\"x\", kind: \"db..x\")\n  puts(w)", "CHECK-ERROR-KIND", "\"db..x\""),
    ("  w: Result[Int] = error(\"x\", kind: \"1db\")\n  puts(w)", "CHECK-ERROR-KIND", "\"1db\""),
    ("  w: Result[Int] = error(kind: \"db\")\n  puts(w)", "CHECK-ARITY", "error(kind: \"db\")"),
    ("  w: Result[Int] = error(\"x\", message: \"y\")\n  puts(w)", "CHECK-DUPLICATE-FIELD", "message"),
    ("  w: Result[Int] = error(\"x\", knd: \"db\")\n  puts(w)", "CHECK-UNKNOWN-FIELD", "knd"),
    ("  w: Result[Int] = error(\"x\", location: \"a\")\n  puts(w)", "CHECK-UNKNOWN-FIELD", "location"),
    ("  w: Result[Int] = error(\"x\", kind: \"a\", kind: \"b\")\n  puts(w)", "CHECK-DUPLICATE-FIELD", "kind"),
    ("  case r\n    ok(n) -> puts(n)\n    error(e) ->\n      w: Result[Int] = error(e, kind: \"x\")\n      puts(w)\n  end",
     "CHECK-ARITY", "kind"),
    ("  w: Result[Int] = error(\"x\", code: \"19\")\n  puts(w)", "CHECK-TYPE-MISMATCH", "\"19\""),
    ("  w: Result[Int] = error(\"x\", code: some(19))\n  puts(w)", "CHECK-TYPE-MISMATCH", "some(19)"),
    ("  w: Result[Int] = error(\"x\", details: {\"a\": 1})\n  puts(w)", "CHECK-TYPE-MISMATCH", "1"),
    ("  w: Result[Int] = error(\"x\", cause: \"y\")\n  puts(w)", "CHECK-TYPE-MISMATCH", "\"y\""),
    ("  w: Result[Int] = error(kind: \"x\", \"m\")\n  puts(w)", "PARSE-UNEXPECTED-TOKEN", "\"m\""),
    ("  w: Result[Int] = \"x\" |> error(kind: \"Bad..Kind\", code: 1)\n  puts(w)", "CHECK-ERROR-KIND",
     "\"Bad..Kind\""),
    ("  w: Result[Int] = \"x\" |> error(kind: \"db\", nope: 3)\n  puts(w)", "CHECK-UNKNOWN-FIELD", "nope"),
    ("  puts(shout(txt: \"x\"))", "CHECK-UNKNOWN-ARGUMENT", "txt: \"x\""),
    ("  case r\n    ok(n) -> puts(n)\n    error(e) if e.is_a?(\"Db\") -> puts(e)\n    error(_) -> puts(1)\n  end",
     "CHECK-ERROR-KIND", "\"Db\""),
    ("  case r\n    ok(n) -> puts(n)\n    error(e) if e.is?(\"db\") -> puts(e)\n    error(_) -> puts(1)\n  end",
     "CHECK-UNKNOWN-METHOD", "e.is?(\"db\")"),
    ("  case r\n    ok(n) -> puts(n)\n    error(e) -> puts(e.is_a?(1))\n  end", "CHECK-TYPE-MISMATCH", "1"),
    # Only error(...) builds an Error.
    ("  e = Error(message: \"x\")\n  puts(e)", "CHECK-ERROR-CONSTRUCTOR", "Error(message: \"x\")"),
]


KINDS_REJECTED = [(uses_r(body), code, text) for body, code, text in KINDS_REJECTED]


@table("body, code, text", KINDS_REJECTED, HEAD)
def test_a_wrong_named_argument_of_error_is_refused(checked, body, code, text):
    program = HEAD % body
    assert_rule(checked(program), program, code, text)


@table("body", VALID, HEAD)
def test_an_error_payload_is_an_error_record(checked, body):
    assert checked(HEAD % body) is None


REJECTED = [
    # The payload is no String: an operator, a String parameter and a String method need its message.
    ("  case r\n    ok(n) -> puts(n)\n    error(msg) -> puts(\"x\" + msg)\n  end", "CHECK-TYPE-MISMATCH", "+"),
    ("  case r\n    ok(n) -> puts(n)\n    error(msg) -> puts(shout(msg))\n  end", "CHECK-TYPE-MISMATCH", "msg"),
    ("  case r\n    ok(n) -> puts(n)\n    error(e) -> puts(e.include?(\"x\"))\n  end", "CHECK-UNKNOWN-METHOD",
     "e.include?(\"x\")"),
    ("  case r\n    ok(n) -> puts(n)\n    error(e) -> puts(e.size)\n  end", "CHECK-UNKNOWN-FIELD", "e.size"),
    ("  case r\n    ok(n) -> puts(n)\n    error(e) -> puts(e == \"empty\")\n  end", "CHECK-TYPE-MISMATCH",
     "\"empty\""),
    # A text literal in the slot of error(...) no longer matches the message.
    ("  case r\n    ok(n) -> puts(n)\n    error(\"empty\") -> puts(0)\n    error(_) -> puts(1)\n  end",
     "CHECK-PATTERN-TYPE", "\"empty\""),
    # error(...) takes a String or an Error.
    ("  bad: Result[Int] = error(42)\n  puts(bad)", "CHECK-TYPE-MISMATCH", "42"),
    ("  bad: Result[Int] = error(r)\n  puts(bad)", "CHECK-TYPE-MISMATCH", "r"),
    # A Result stays out of JSON, though the Error it holds is encodable.
    ("  puts(JSON.encode(r))", "CHECK-NOT-ENCODABLE", "r"),
]


@table("body, code, text", REJECTED, HEAD)
def test_an_error_payload_is_not_a_string(checked, body, code, text):
    program = HEAD % body
    assert_rule(checked(program), program, code, text)


ERROR_PREDICATE = [
    ("  r: Result[Void] = error(\"x\")\n  puts(r.error?)", "r.error?"),
    ("  rs: List[Result[Void]] = []\n  puts(rs.select do |result| result.error? end)", "result.error?"),
]


@pytest.mark.parametrize("body, text", ERROR_PREDICATE)
def test_error_predicate_help_is_about_a_result(body, text, tmp_path):
    program = "def main() -> Void\n" + body + "\nend\n"
    found = check_diagnostic(program, tmp_path)
    assert_rule(found, program, "CHECK-UNKNOWN-METHOD", text)
    assert "unwrap" not in found["help"]
