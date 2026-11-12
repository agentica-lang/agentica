"""Nothing chains after the `end` of a `do` block, through `agentica --json check`: a `.name`, an index or a `|>` right
after that `end` is CHECK-CHAIN-AFTER-END, from the `end` to the link, while a block in braces, a lambda and a binary
operator after `end` stay valid. Each case asserts the code and the source text its range covers, never the message.
"""

from tests.spec_support import Batch, assert_rule

BATCH = Batch("program.agc")
table = BATCH.table
checked = BATCH.fixture()

HEAD = """def size_of(xs: List[Int]) -> Int = xs.size

def plus(n: Int, xs: List[Int]) -> Int = n + xs.size

def main() -> Void
  xs = [1, 2]
  puts(xs)
%s
end
"""

VALID = [
    # A chain after a block in braces, and a do block whose result is bound first.
    '  puts(xs.map { |x| x.to_s }.join(", "))',
    "  ys = xs.map do |x| x * 2 end\n  puts(ys.size)",
    # A brace block chained inside a do block, with nothing after the do block's end.
    "  n = xs.map do |x| x + xs.map { |y| y }.size end\n  puts(n)",
    # A lambda may be called right away.
    "  g = ->(x: Int) { x + 1 }.call(1)\n  puts(g)",
    # A binary operator after end, and a do block as an argument of a piped call.
    "  ys = xs.map do |x| x end + xs\n  puts(ys)",
    "  n = 1 |> plus(xs.map do |x| x end)\n  puts(n)",
]


@table("body", VALID, HEAD)
def test_a_block_in_braces_a_lambda_and_an_operator_may_follow(checked, body):
    assert checked(HEAD % body) is None


REJECTED = [
    # A method, an index or a pipe right after end; the span goes from end to the link.
    ("  n = xs.map do |x| x end.size\n  puts(n)", "end.size"),
    ('  puts(xs.map do |x| x.to_s end.join(", "))', "end.join"),
    ("  n = xs.map do |x| x end[0]\n  puts(n)", "end[0]"),
    ("  n = xs.map do |x| x end |> size_of()\n  puts(n)", "end |> size_of()"),
    # A leading dot on the next line is the same chain, and so is the call in parentheses, which fmt drops.
    ("  n = xs.map do |x|\n    x\n  end\n    .size\n  puts(n)", "end\n    .size"),
    ("  n = (xs.map do |x| x end).size\n  puts(n)", "end).size"),
    # A call with arguments before the block, whose block cannot be in braces.
    ("  n = xs.each_slice(1) do |s| s end.size\n  puts(n)", "end.size"),
    # Nested: a do block inside a brace block, and the end of a do block that holds a chained brace block.
    ("  n = xs.map { |x| x + xs.map do |y| y end.size }\n  puts(n)", "end.size"),
    ("  n = xs.map do |x| x + xs.map { |y| y }.size end.size\n  puts(n)", "end.size"),
    # An index after end, then .call on the lambda it gives.
    ("  g = xs.map do |x| ->(y: Int) { y + x } end[0].call(1)\n  puts(g)", "end[0]"),
]


@table("body, text", REJECTED, HEAD)
def test_a_chain_after_the_end_of_a_do_block(checked, body, text):
    program = HEAD % body
    assert_rule(checked(program), program, "CHECK-CHAIN-AFTER-END", text)


NOT_BLOCKS = [
    # There is no &. operator, and the end of a while or a case value takes no chain: the parser refuses them first.
    ("  n = xs.map do |x| x end&.size\n  puts(n)", "&"),
    ("  while false\n  end.to_s", "."),
    ("  y = case xs.size\n    1 -> 1\n    _ -> 2\n  end.to_s\n  puts(y)", "."),
]


@table("body, text", NOT_BLOCKS, HEAD)
def test_other_chains_after_end_are_parse_errors(checked, body, text):
    program = HEAD % body
    assert_rule(checked(program), program, "PARSE-UNEXPECTED-TOKEN", text)
