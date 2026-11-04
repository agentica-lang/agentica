## `agentica lint` as a stage: the text of one file in, the suggestions of the style guide out, or the first lexer or
## parser diagnostic. The file is only lexed and parsed, so the rules read the syntax tree and no types: a rule that
## needs a type to be sure does not exist here. Every rule is a function of rule_*.agc; this file walks the tree once
## and gives each node to them.
##
## The walk uses a worklist, as ast_walk.agc does, and tells each node two things the rules need from above: whether it
## is below a loop of the same function body, and whether it is the first operand of a pipe or of a `+` chain (the
## expression above it speaks for the whole chain).

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
  in_loop: Bool
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
    Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem)
    Diag.Outcome.Done(tokens) ->
      case Parser.parse(tokens, 0)
        Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem)
        Diag.Outcome.Done(program) -> return Diag.Outcome.Done(of_program(file, program))
      end
  end
end

def of_program(file: String, program: Ast.Program) -> List[Problems.Problem]
  found: List[Problems.Problem] = []
  mentions: List[Qualified.Mention] = []
  imports: List[Ast.ImportDecl] = []
  for decl in program.declarations
    for suggestion in Decls.suggestions(file, decl)
      found = found.push(suggestion)
    end

    case decl
      Ast.Decl.Import(node) -> imports = imports.push(node)
      _ -> imports = imports
    end

    scan = scan_decl(file, decl)
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

  return found.sort_by do |suggestion: Problems.Problem| suggestion.span.start.offset end
end

# The walk of a function body or of the value of a constant, `export` or not.
def scan_decl(file: String, decl: Ast.Decl) -> Scan
  case decl
    Ast.Decl.Export(node) -> return scan_decl(file, node.declaration)
    Ast.Decl.Function(node) ->
      roots = node.body.map do |stmt: Ast.Stmt| Walk.Node.Stmt(stmt) end
      return scan(file, roots, function_locals(node, roots))
    Ast.Decl.Constant(node) ->
      return scan(file, [Walk.Node.Expr(node.value)], Stmts.Locals(strings: Set.new([]), outer: Set.new([])))
    _ -> return Scan(found: [], mentions: [])
  end
end

def scan(file: String, roots: List[Walk.Node], locals: Stmts.Locals) -> Scan
  found: List[Problems.Problem] = []
  mentions: List[Qualified.Mention] = []
  work: List[Item] = roots.map do |node: Walk.Node| Item(node: node, in_loop: false, chained: false) end
  at = 0
  while at < work.size
    item = work[at]
    at += 1
    for suggestion in suggestions(file, item, locals)
      found = found.push(suggestion)
    end

    for mention in Qualified.mentions(item.node)
      mentions = mentions.push(mention)
    end

    for child in children(item)
      work = work.push(child)
    end
  end

  return Scan(found: found, mentions: mentions)
end

def suggestions(file: String, item: Item, locals: Stmts.Locals) -> List[Problems.Problem]
  case item.node
    Walk.Node.Expr(expr) -> return Exprs.suggestions(file, expr, item.chained)
    Walk.Node.Stmt(stmt) -> return Stmts.suggestions(file, stmt, item.in_loop, locals)
  end
end

# The children of the item, each with its place. The template of an `<<~EAG` literal is code the parser made, not code
# the author wrote, so it is not walked.
def children(item: Item) -> List[Item]
  if template?(item.node)
    return []
  end

  looped = in_loop(item)
  out: List[Item] = []
  for kid in Walk.children(item.node)
    out = out.push(Item(node: kid, in_loop: looped, chained: out.size == 0 and first_is_chained?(item)))
  end

  return out
end

def template?(node: Walk.Node) -> Bool
  case node
    Walk.Node.Expr(Ast.Expr.EagLit(_)) -> return true
    _ -> return false
  end
end

# Whether the children of the item are below a loop: a `for` or `while` starts one, a block starts again.
def in_loop(item: Item) -> Bool
  case item.node
    Walk.Node.Stmt(Ast.Stmt.For(_)) -> return true
    Walk.Node.Stmt(Ast.Stmt.While(_)) -> return true
    Walk.Node.Expr(Ast.Expr.BlockLit(_)) -> return false
    _ -> return item.in_loop
  end
end

# Whether the first child of the item is the first operand of a chain that the item continues: the value a pipe passes
# on, the left side of a `+`, or the same for a `try` that wraps the chain.
def first_is_chained?(item: Item) -> Bool
  case item.node
    Walk.Node.Expr(Ast.Expr.Call(node)) -> return node.piped
    Walk.Node.Expr(Ast.Expr.Binary(node)) -> return node.op == "plus"
    Walk.Node.Expr(Ast.Expr.Try(_)) -> return item.chained
    _ -> return false
  end
end

# The names of a function that matter to the String rule (Stmts.Locals): the String ones, and those bound outside every
# loop. The parameters are bound before any loop. The walk gives each binding its place, as the main walk does.
def function_locals(decl: Ast.FunctionDecl, roots: List[Walk.Node]) -> Stmts.Locals
  strings: Set[String] = Set.new([])
  outer: Set[String] = Set.new([])
  for param in decl.params
    outer = outer.add(param.name)
    if param.type.name == "String"
      strings = strings.add(param.name)
    end
  end

  work: List[Item] = roots.map do |node: Walk.Node| Item(node: node, in_loop: false, chained: false) end
  at = 0
  while at < work.size
    item = work[at]
    at += 1
    case item.node
      Walk.Node.Stmt(Ast.Stmt.Binding(binding)) ->
        if string_binding?(binding)
          strings = strings.add(binding.name)
        end

        if !item.in_loop
          outer = outer.add(binding.name)
        end

      _ -> outer = outer
    end

    for child in children(item)
      work = work.push(child)
    end
  end

  return Stmts.Locals(strings: strings, outer: outer)
end

def string_binding?(binding: Ast.Binding) -> Bool
  case binding.type
    some(declared) -> return declared.name == "String"
    none -> return Shape.text?(binding.value)
  end
end
