"""Safe navigation over an Optional, through `agentica --json check`: `o&.name` and `o&.name(args)` read a field or
call a method of the value inside `o` and give an Optional. A receiver that is not an Optional is
CHECK-SAFE-NAV-RECEIVER at the `&.`; any other problem is the one that `.` would report. Each case asserts the code and
the source text its range covers, never the message. What runs (`none` skips the arguments, the flattening, the
chains) is the VM golden tests/fixtures/vm/safe-navigation.agc.
"""

from tests.spec_support import Batch, assert_rule

BATCH = Batch("main.agc")
table = BATCH.table
checked = BATCH.fixture()

HEAD = """struct Address
  city: String
  zip: Optional[String]
end

struct User
  name: String
  address: Optional[Address]
end

def show(user: User, words: Optional[List[String]]) -> Void
%s
end
"""

VALID = [
    # A field, a method without arguments, and a method with arguments and a block.
    '  city: Optional[String] = user.address&.city\n  puts(city)',
    "  n: Optional[Int] = words&.size\n  puts(n)",
    '  joined: Optional[String] = words&.join(",")\n  puts(joined)',
    "  lengths: Optional[List[Int]] = words&.map do |w| w.size end\n  puts(lengths)",
    # The member is an Optional itself: the result is that Optional, and a chain of &. has one level.
    "  zip: Optional[String] = user.address&.zip\n  puts(zip)",
    '  puts(user.address&.zip&.size)',
    # A plain dot after &.x applies to the Optional it gave.
    '  puts(user.address&.city.unwrap_or("?"))',
    # A member that gives nothing is Void, run for some and skipped for none; inside a lambda and a block.
    "  words&.each do |w| puts(w) end",
    '  f = ->(o: Optional[String]) { o&.size }\n  puts(f.call(some("a")))',
    "  puts(words&.map do |w| some(w)&.size.unwrap_or(0) end)",
    # The Optional comes from the context: a lambda with a typed variable, and a block over a list of Optionals.
    "  f: Fn[Optional[User], Optional[String]] = ->(u) { u&.address&.city }\n  puts(f.call(some(user)))",
    "  rows: List[Optional[User]] = [some(user), none]\n  puts(rows.map do |row| row&.address&.city end)",
    # A line that starts with &.name continues the line before.
    "  n = user.address\n    &.city\n    &.size\n  puts(n)",
]


@table("body", VALID, HEAD)
def test_safe_navigation_over_an_optional_checks(checked, body):
    assert checked(HEAD % body) is None


REJECTED = [
    # A receiver that is not an Optional: the code is at the &.
    ("  n = user&.name\n  puts(n)", "CHECK-SAFE-NAV-RECEIVER", "&."),
    ("  puts(user.name&.size)", "CHECK-SAFE-NAV-RECEIVER", "&."),
    ("  puts([1, 2]&.size)", "CHECK-SAFE-NAV-RECEIVER", "&."),
    ('  puts(user.name&.start_with?("a"))', "CHECK-SAFE-NAV-RECEIVER", "&."),
    # A type or a module before &. is no Optional either, and does not compile as `.`.
    ("  puts(User&.members)", "CHECK-SAFE-NAV-RECEIVER", "&."),
    ('  puts(OpenSSL.Digest&.sha256("x"))', "CHECK-SAFE-NAV-RECEIVER", "&."),
    # What `.` would report on the value inside.
    ("  puts(user.address&.street)", "CHECK-UNKNOWN-FIELD", "user.address&.street"),
    ("  puts(words&.nope(1))", "CHECK-UNKNOWN-METHOD", "words&.nope(1)"),
    ('  puts(words&.join(",", 1))', "CHECK-ARITY", 'words&.join(",", 1)'),
    # No &.call: the function inside an Optional is called after a case. A Void member has no value.
    ("  cb: Optional[Fn[Int, Int]] = none\n  puts(cb&.call(1))", "CHECK-UNKNOWN-METHOD", "cb&.call(1)"),
    ("  x = words&.each do |w| puts(w) end\n  puts(x)", "CHECK-VOID-VALUE", "words&.each do |w| puts(w) end"),
    # The result is an Optional, not the member.
    ("  city: String = user.address&.city\n  puts(city)", "CHECK-TYPE-MISMATCH", "user.address&.city"),
]


@table("body, code, text", REJECTED, HEAD)
def test_safe_navigation_on_a_value_that_is_not_an_optional_or_a_member_that_is_missing(checked, body, code, text):
    program = HEAD % body
    assert_rule(checked(program), program, code, text)



MODULE_BLOCK = {
    "lib.agc": "module Net\n  def ping() -> Int = 1\nend\n",
    "main.agc": 'import L from "lib"\n\ndef main() -> Void\n  puts(L.Net&.ping())\nend\n',
}


@table("files", [MODULE_BLOCK], lambda files: files)
def test_a_module_block_of_an_alias_before_the_operator_is_not_an_optional(checked, files):
    assert_rule(checked(files), files["main.agc"], "CHECK-SAFE-NAV-RECEIVER", "&.")
