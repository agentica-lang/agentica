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
    # What `.` would report on the value inside.
    ("  puts(user.address&.street)", "CHECK-UNKNOWN-FIELD", "user.address&.street"),
    ("  puts(words&.nope(1))", "CHECK-UNKNOWN-METHOD", "words&.nope(1)"),
    # The result is an Optional, not the member.
    ("  city: String = user.address&.city\n  puts(city)", "CHECK-TYPE-MISMATCH", "user.address&.city"),
]


@table("body, code, text", REJECTED, HEAD)
def test_safe_navigation_on_a_value_that_is_not_an_optional_or_a_member_that_is_missing(checked, body, code, text):
    program = HEAD % body
    assert_rule(checked(program), program, code, text)

