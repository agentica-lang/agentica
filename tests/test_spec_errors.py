"""The builtin Error record (#671), through `agentica --json check`: a failed Result holds an Error, which the pattern
`error(e)` binds and `error(...)` builds from a String or passes on. Each case asserts the code and the source text its
range covers, never the message. What the forms print is the VM golden tests/fixtures/vm/error-record.agc.
"""

from tests.spec_support import Batch, assert_rule

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


@table("body", VALID, HEAD)
def test_an_error_payload_is_an_error_record(checked, body):
    assert checked(HEAD % body) is None


REJECTED = [
    # The payload is no String: an operator, a String parameter and a String method need its message.
    ("  case r\n    ok(n) -> puts(n)\n    error(msg) -> puts(\"x\" + msg)\n  end", "CHECK-TYPE-MISMATCH", "+"),
    ("  case r\n    ok(n) -> puts(n)\n    error(msg) -> puts(shout(msg))\n  end", "CHECK-TYPE-MISMATCH", "msg"),
    ("  case r\n    ok(n) -> puts(n)\n    error(e) -> puts(e.include?(\"x\"))\n  end", "CHECK-UNKNOWN-METHOD",
     "e.include?(\"x\")"),
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
