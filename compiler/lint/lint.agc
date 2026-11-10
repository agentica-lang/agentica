## `agentica lint` as a stage: the text of one file in, the suggestions of the style guide out, or the first lexer or
## parser diagnostic. The file is only lexed and parsed, so the rules read the syntax tree and no types: a rule that
## needs a type to be sure does not exist here. Every rule is a function of rule_*.agc; this file walks the tree once
## and gives each node to them.
##
## The walk uses a worklist, as ast_walk.agc does, and tells each node two things the rules need from above: whether it
## is below a loop of the same function body, and whether it is the first operand of a pipe, of a `+` chain or of a
## plain call (the expression above it speaks for the whole chain).

import Diag from "../diagnostics/diagnostic"
import Problems from "../diagnostics/problem"
import Ast from "../syntax/ast"
import Walk from "../syntax/ast_walk"
import Lexer from "../syntax/lexer"
import Parser from "../syntax/parser"
import Decls from "rule_decl"
import Exprs from "rule_expr"
import Qualified from "rule_qualified"
import Stmts from "rule_stmt"
import Shape from "shape"

# A node and what the walk knows of its place.
struct Item
  node: Walk.Node
  path: List[Int]
  chained: Bool
end

# What the walk of some roots found: suggestions, and the qualified names it saw.
struct Scan
  found: List[Problems.Problem]
  mentions: List[Qualified.Mention]
end

## The suggestions for the text of `file`, in source order, or the first lexer or parser diagnostic.
export def check(file: String, text: String) -> Diag.Outcome[List[Problems.Problem]]
  case Lexer.lex(text)
    Diag.Outcome.Failed(problem) -> Diag.Outcome.Failed(problem)
    Diag.Outcome.Done(tokens) ->
      case Parser.parse(tokens, 0)
        Diag.Outcome.Failed(problem) -> Diag.Outcome.Failed(problem)
        Diag.Outcome.Done(program) -> Diag.Outcome.Done(of_program(file, program))
      end
  end
end

def of_program(file: String, program: Ast.Program) -> List[Problems.Problem]
  found: List[Problems.Problem] = []
  mentions: List[Qualified.Mention] = []
  imports: List[Ast.ImportDecl] = []
  aliases = module_aliases(program)
  for decl in program.declarations
    for suggestion in Decls.suggestions(file, decl)
      found = found.push(suggestion)
    end

    case decl
      Ast.Decl.Import(node) -> imports = imports.push(node)
      _ -> imports = imports
    end

    scan = scan_decl(file, decl, aliases)
    for suggestion in scan.found
      found = found.push(suggestion)
    end

    for mention in scan.mentions
      mentions = mentions.push(mention)
    end
  end

  for suggestion in Qualified.suggestions(file, mentions, imports)
    found = found.push(suggestion)
  end

  found.sort_by do |suggestion: Problems.Problem| suggestion.span.start.offset end
end

# The aliases of the modules that the file imports (`import Paths from "..."`).
def module_aliases(program: Ast.Program) -> Set[String]
  found: Set[String] = Set.new([])
  for decl in program.declarations
    case decl
      Ast.Decl.Import(node) ->
        case node.alias
          some(alias) -> found = found.add(alias)
          none -> next
        end

      _ -> next
    end
  end

  found
end

# The walk of a function body or of the value of a constant, `export` or not.
def scan_decl(file: String, decl: Ast.Decl, aliases: Set[String]) -> Scan
  case decl
    Ast.Decl.Export(node) -> scan_decl(file, node.declaration, aliases)
    Ast.Decl.Function(node) ->
      roots = node.body.map do |stmt: Ast.Stmt| Walk.Node.Stmt(stmt) end
      scan(file, roots, function_locals(node, roots, aliases), aliases)
    Ast.Decl.Constant(node) -> scan(file, [Walk.Node.Expr(node.value)], Stmts.Locals(origins: {}), aliases)
    _ -> Scan(found: [], mentions: [])
  end
end

def scan(file: String, roots: List[Walk.Node], locals: Stmts.Locals, aliases: Set[String]) -> Scan
  found: List[Problems.Problem] = []
  mentions: List[Qualified.Mention] = []
  work: List[Item] = roots.map do |node: Walk.Node| Item(node: node, path: [], chained: false) end
  at = 0
  while at < work.size
    item = work[at]
    at += 1
    for suggestion in suggestions(file, item, locals, aliases)
      found = found.push(suggestion)
    end

    for mention in Qualified.mentions(item.node)
      mentions = mentions.push(mention)
    end

    for child in children(item, aliases)
      work = work.push(child)
    end
  end

  Scan(found: found, mentions: mentions)
end

def suggestions(file: String, item: Item, locals: Stmts.Locals, aliases: Set[String]) -> List[Problems.Problem]
  case item.node
    Walk.Node.Expr(expr) -> Exprs.suggestions(file, expr, item.chained, aliases)
    Walk.Node.Stmt(stmt) -> Stmts.suggestions(file, stmt, item.path, locals)
  end
end

# The children of the item, each with its place. The template of an `<<~EAG` literal is code the parser made, not code
# the author wrote, so it is not walked.
def children(item: Item, aliases: Set[String]) -> List[Item]
  return [] if template?(item.node)

  looped = path_below(item)
  out: List[Item] = []
  for kid in Walk.children(item.node)
    out = out.push(Item(node: kid, path: looped, chained: out.size == 0 and continues?(item, kid, aliases)))
  end

  out
end

def template?(node: Walk.Node) -> Bool
  case node
    Walk.Node.Expr(Ast.Expr.EagLit(_)) -> true
    _ -> false
  end
end

# The loops that the children of the item sit in: a `for` or `while` adds its id, a block starts again.
def path_below(item: Item) -> List[Int]
  case item.node
    Walk.Node.Stmt(Ast.Stmt.For(loop)) -> item.path.push(loop.id)
    Walk.Node.Stmt(Ast.Stmt.While(loop)) -> item.path.push(loop.id)
    Walk.Node.Expr(Ast.Expr.BlockLit(_)) -> []
    _ -> item.path
  end
end

# Whether `first`, the first child of the item, is the first operand of a chain that the item continues: the value a
# pipe passes on, the left side of a `+`, or the first argument of a step that is a step too (a nest, Exprs.step?).
# Only a child of the same chain counts: in `(a + b.to_s) |> f()` and in `a |> f() + "x"` the child is a chain of the
# other kind, which nobody has judged yet. A `try` that wraps a pipe is part of it when the `try` is; a `+` does not
# look through a `try` (Shape.plus_operands), so the `+` inside is its own chain.
def continues?(item: Item, first: Walk.Node, aliases: Set[String]) -> Bool
  kind = chain_kind(item.node, aliases)
  return false if kind == "" or kind != chain_kind(first, aliases)

  case item.node
    Walk.Node.Expr(Ast.Expr.Try(_)) -> item.chained
    _ -> true
  end
end

# "pipe" for a piped call, "nest" for a call that is a step, "plus" for a `+`, "pipe" for a `try` around a piped call,
# and "" for anything else: a builtin call breaks a nest, so `puts(f(g(h(x))))` is judged at `f`.
def chain_kind(node: Walk.Node, aliases: Set[String]) -> String
  case node
    Walk.Node.Expr(Ast.Expr.Call(call)) ->
      if call.piped
        return "pipe"
      elsif Exprs.step?(call, aliases)
        return "nest"
      end

      ""
    Walk.Node.Expr(Ast.Expr.Binary(binary)) ->
      return "plus" if binary.op == "plus"

      ""
    Walk.Node.Expr(Ast.Expr.Try(wrapper)) ->
      return "pipe" if chain_kind(Walk.Node.Expr(wrapper.operand), aliases) == "pipe"

      ""
    _ -> ""
  end
end

# Where each name of a function was set (Stmts.Origin): the parameters first, then every binding with the loops around
# it. The walk gives each binding its place, as the main walk does.
def function_locals(decl: Ast.FunctionDecl, roots: List[Walk.Node], aliases: Set[String]) -> Stmts.Locals
  origins: Map[String, List[Stmts.Origin]] = {}
  for param in decl.params
    origin = Stmts.Origin(offset: -1, path: [], string: param.type.name == "String")
    origins = origins.put(param.name, origins.get(param.name, []).push(origin))
  end

  work: List[Item] = roots.map do |node: Walk.Node| Item(node: node, path: [], chained: false) end
  at = 0
  while at < work.size
    item = work[at]
    at += 1
    case item.node
      Walk.Node.Stmt(Ast.Stmt.Binding(binding)) ->
        origin = Stmts.Origin(offset: binding.span.start.offset, path: item.path, string: string_binding?(binding))
        origins = origins.put(binding.name, origins.get(binding.name, []).push(origin))

      _ -> origins = origins
    end

    for child in children(item, aliases)
      work = work.push(child)
    end
  end

  Stmts.Locals(origins: origins)
end

def string_binding?(binding: Ast.Binding) -> Bool
  case binding.type
    some(declared) -> declared.name == "String"
    none -> Shape.text?(binding.value)
  end
end
