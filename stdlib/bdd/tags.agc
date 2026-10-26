## Reads the tag expressions of `agentica test --tags`.
##
## A small subset of Cucumber's tag expressions: `@a`, `not @a`, joined with `and` and `or`. `not` binds tighter than
## `and`, and `and` tighter than `or`; a `not` before a `not` cancels it. There are no parentheses. Words are
## separated by any white space, no-break spaces included.

## One tag, or its negation.
struct Literal
  tag: String
  negated: Bool
end

## A tag expression: groups joined with `or`, each a list of literals joined with `and`. No groups selects everything.
export struct Expr
  groups: List[List[Literal]]
end

## Reads `text`. Returns the expression, or an error whose message says what is wrong. An empty text is the expression
## that selects every scenario.
export def compile(text: String) -> Result[Expr]
  spaced = text.split("").map do |character| separator(character) end.join("")
  words = spaced.split(" ").filter do |word| word != "" end
  if words.size == 0
    return ok(Expr(groups: []))
  end

  groups: List[List[Literal]] = []
  group: List[Literal] = []
  # What the next word may be: a tag or `not` (a literal), or `and` / `or` (after a tag).
  literal = true
  negated = false
  for word in words
    if literal and word == "not"
      negated = not negated
    elsif literal and word.length > 1 and word.start_with?("@")
      group = group.push(Literal(tag: word, negated: negated))
      negated = false
      literal = false
    elsif not literal and word == "and"
      literal = true
    elsif not literal and word == "or"
      groups = groups.push(group)
      group = []
      literal = true
    else
      return error("unexpected #{word.inspect}; write a tag (@name), not, and, or")
    end
  end

  if literal
    return error("the expression must end with a tag")
  end

  return ok(Expr(groups: groups.push(group)))
end

## Whether the expression selects a scenario that has `tags` (with their `@`).
export def selects?(expr: Expr, tags: List[String]) -> Bool
  if expr.groups.size == 0
    return true
  end

  return expr.groups.any? do |group| holds?(group, tags) end
end

## Whether the expression leaves some scenarios out, that is, whether `--tags` was given.
export def filters?(expr: Expr) -> Bool
  return expr.groups.size > 0
end

# A space for any character that separates words: the ASCII and Unicode white space.
def separator(character: String) -> String
  point = String.code(character)
  spacing = (point >= 9 and point <= 13) or point == 133 or point == 160 or point == 5760
  spacing = spacing or (point >= 8192 and point <= 8202) or point == 8232 or point == 8233
  spacing = spacing or point == 8239 or point == 8287 or point == 12288
  if spacing
    return " "
  end

  return character
end

# Every literal of the group: a tag is there, or a negated one is not.
def holds?(group: List[Literal], tags: List[String]) -> Bool
  return group.all? do |item| has_tag?(tags, item.tag) != item.negated end
end

def has_tag?(tags: List[String], wanted: String) -> Bool
  return tags.any? do |tag| tag == wanted end
end
