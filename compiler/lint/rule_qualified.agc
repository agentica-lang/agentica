## The rule for a qualified type name that a file writes many times (`Db.Value.Text(...)`, `Db.Value.Null`): the style
## guide imports a name used often (`import {Value} from "db"`). The walk collects each mention; the rule counts them.

import Problems from "../diagnostics/problem"
import Ast from "../syntax/ast"
import Source from "../syntax/source"
import Walk from "../syntax/ast_walk"
import Rules from "rules"

# How many times a file writes the same qualified name before importing it by name pays.
LIMIT = 20

## One use of an alias-qualified type name, such as `Db.Value`, and where it is.
export struct Mention
  name: String
  span: Source.Span
end

## The qualified type names that the node writes: a variant or struct built, a variant in a pattern and a type name
## in an expression. A name with no `.` has no alias and is not a mention. A local enum variant (`Answer.SignedOut`)
## has a `.` too; `suggestions` drops it, as its first part is not an import alias.
export def mentions(node: Walk.Node) -> List[Mention]
  case node
    Walk.Node.Expr(expr) -> return of_expr(expr)
    Walk.Node.Stmt(stmt) -> return of_stmt(stmt)
  end
end

## One suggestion for each qualified name that `found` holds `LIMIT` times or more, at the first place it is written.
## Only a name whose first part is the alias of an import counts: that is the only name that importing by name
## shortens, and `imports` then give the path for the help.
export def suggestions(file: String, found: List[Mention], imports: List[Ast.ImportDecl]) -> List[Problems.Problem]
  counts: Map[String, Int] = {}
  firsts: Map[String, Source.Span] = {}
  aliases = alias_names(imports)
  imported = found.select do |mention: Mention| aliases.include?(mention.name.split(".")[0]) end
  for mention in imported
    counts = counts.put(mention.name, counts.get(mention.name, 0) + 1)
    if !firsts.has_key?(mention.name) or mention.span.start.offset < firsts[mention.name].start.offset
      firsts = firsts.put(mention.name, mention.span)
    end
  end

  out: List[Problems.Problem] = []
  for name in counts.keys
    if counts[name] >= LIMIT
      rule = Rules.REPEATED_NAME
      out = out.push(
        Rules.at(file, rule.with(message: message(name, counts[name]), help: help(name, imports)), firsts[name]),
      )
    end
  end

  return out
end

def alias_names(imports: List[Ast.ImportDecl]) -> Set[String]
  names: Set[String] = Set.new([])
  for item in imports
    case item.alias
      some(alias) -> names = names.add(alias)
      none -> names = names
    end
  end

  return names
end

def message(name: String, count: Int) -> String
  return "#{name} is built or matched #{count} times in this file"
end

# `import {Value} from "db"` for `Db.Value`, with the path of the import that binds `Db`; when the file already imports
# the name from that path, the help says to write it as it is bound.
def help(name: String, imports: List[Ast.ImportDecl]) -> String
  parts = name.split(".")
  local = parts[parts.size - 1]
  path = ""
  for item in imports
    if item.alias == some(parts[0])
      path = item.path
    end
  end

  for item in imports
    if item.path == path
      case bound_as(item, local)
        some(bound) -> return "`#{bound}` is already imported from \"#{path}\": write it in place of `#{name}`"
        none -> path = path
      end
    end
  end

  return "import it by name: `import {#{local}} from \"#{path}\"` (`as V` gives a shorter name)"
end

# The name that `import {name}` of the declaration binds, `none` when it does not import `name`.
def bound_as(item: Ast.ImportDecl, name: String) -> Optional[String]
  for imported in item.names
    if imported.name == name
      return some(imported.local)
    end
  end

  return none
end

def of_expr(expr: Ast.Expr) -> List[Mention]
  case expr
    Ast.Expr.EnumConstructor(node) -> return qualified(node.enum_name, node.span)
    Ast.Expr.Construct(node) -> return qualified(node.type_name, node.span)
    Ast.Expr.TypeName(node) -> return qualified(node.name, node.span)
    Ast.Expr.Case(node) -> return case_mentions(node)
    _ -> return []
  end
end

def qualified(name: String, span: Source.Span) -> List[Mention]
  if name.contains?(".")
    return [Mention(name: name, span: span)]
  end

  return []
end

# The patterns of a `case` and the patterns nested in them, walked with a worklist.
def of_stmt(stmt: Ast.Stmt) -> List[Mention]
  case stmt
    Ast.Stmt.Case(node) -> return case_mentions(node)
    _ -> return []
  end
end

def case_mentions(node: Ast.CaseStmt) -> List[Mention]
  work: List[Ast.Pattern] = node.arms.map do |arm: Ast.CaseArm| arm.pattern end
  found: List[Mention] = []
  at = 0
  while at < work.size
    current = work[at]
    at += 1
    found = found.concat(pattern_mentions(current))
    work = work.concat(nested_patterns(current))
  end

  return found
end

# The qualified name that the pattern itself writes: a variant, and nothing else.
def pattern_mentions(pattern: Ast.Pattern) -> List[Mention]
  case pattern
    Ast.Pattern.Variant(variant) -> return qualified(variant.enum_name, variant.span)
    Ast.Pattern.Wildcard(_) -> return []
    Ast.Pattern.Literal(_) -> return []
  end
end

# The patterns inside the slots of a variant pattern.
def nested_patterns(pattern: Ast.Pattern) -> List[Ast.Pattern]
  inner: List[Ast.Pattern] = []
  case pattern
    Ast.Pattern.Variant(variant) ->
      for slot in variant.slots
        case slot
          Ast.Slot.Nested(nested) -> inner = inner.push(nested)
          _ -> inner = inner
        end
      end

    Ast.Pattern.Wildcard(_) -> inner = inner
    Ast.Pattern.Literal(_) -> inner = inner
  end

  return inner
end
