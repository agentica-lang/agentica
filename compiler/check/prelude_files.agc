## The compiler prelude (docs/future/25-ruby-typed-idioms.md 25.6): the methods written in Agentica in stdlib/prelude/
## (List.find, List.group_by ...). The checker (check_prelude.agc) records, for each call of such a method, which
## function runs it. Here the files of those functions are read, parsed and checked once the program is, and only the
## functions the program calls are kept, so a program that calls none pays nothing. The functions are then part of the
## program like any other: they are lowered with it, in files whose names start with "<prelude>/", which the VM treats
## as the prelude (docs/vm/03-ir-and-bytecode.md).
##
## A prelude function is named Names.prelude_name(module + "::" + name), so it cannot meet a function of the program.
## The files are not modules: no program imports them (resolve_import.agc), and they call builtins only, never each
## other.

import Diag from "../diagnostics/diagnostic"
import Failure from "../diagnostics/problem"
import Env from "../modules/link_env"
import Linker from "../modules/linker"
import Resolve from "../modules/resolve_import"
import Ast from "../syntax/ast"
import Lexer from "../syntax/lexer"
import Parser from "../syntax/parser"
import Names from "../syntax/prelude_name"
import {PRELUDE_PREFIX} from "../syntax/prelude_name"
import Source from "../syntax/source"
import SourceFile from "../syntax/source_file"
import T from "../syntax/types"
import Register from "check_register"
import State from "check_state"
import Statements from "check_stmt"

## The prelude files a program needs, added to the program: the state with room for their node ids, and their modules.
export struct Attached
  st: State.St
  modules: List[Linker.LinkedModule]
end

## The type variables the signatures of the prelude functions may use: the letters of the catalog rows.
export def variables() -> List[String]
  return ["A", "B", "K", "V"]
end

## Reads, checks and returns the prelude functions that st.bodies names. base is the context of the program before its
## declarations were registered, and the node ids of the prelude files start at the end of the ids of the program.
export def attach(settings: Env.Settings, base: State.Cx, st: State.St) -> Result[Attached]
  if st.bodies.size == 0
    return ok(Attached(st: st, modules: []))
  end

  wanted = wanted_functions(st.bodies.values)
  modules: List[Linker.LinkedModule] = []
  first_id = st.types.size
  for module in wanted.keys
    loaded = try load(settings, module, wanted[module], first_id)
    modules = modules.push(loaded)
    first_id = loaded.next_id
  end

  texts = base.texts
  for module in modules
    texts = texts.put(module.file, module.text)
  end

  cx = base.with(prelude: true, type_params: variables(), texts: texts)
  cx = try Register.register(cx, modules)
  grown = st.with(types: st.types.concat(List.repeat(T.Type.Unknown, first_id - st.types.size)))
  for module in modules
    for decl in module.declarations
      case decl
        Ast.Decl.Function(node) -> grown = try Statements.check_function(cx.with(file: module.file), grown, node)
        _ -> grown = grown
      end
    end
  end

  return ok(Attached(st: grown, modules: modules))
end

# The functions of each file that the program calls, by file stem, in the order the calls were checked.
def wanted_functions(keys: List[String]) -> Map[String, List[String]]
  found: Map[String, List[String]] = {}
  for key in keys
    at = key.index_of("::").unwrap!
    module = key.slice(0, at)
    function = key.slice(at + 2, key.length - at - 2)
    before = found.get(module)
    names: List[String] = []
    if before.ok?
      names = before.unwrap!
    end

    if !names.any? do |name: String| name == function end
      found = found.put(module, names.push(function))
    end
  end

  return found
end

# One file: read, parsed from first_id, and cut down to the functions wanted, which get their prelude names.
def load(settings: Env.Settings, module: String, functions: List[String], first_id: Int) -> Result[Linker.LinkedModule]
  file = "#{PRELUDE_PREFIX}#{module}.agc"
  text = try read(settings, "std/prelude/#{module}.agc", file)
  program = try parse(file, text, first_id)
  kept: List[Ast.Decl] = []
  for decl in program.declarations
    case decl
      Ast.Decl.Function(node) ->
        if functions.any? do |name: String| name == node.name end
          kept = kept.push(Ast.Decl.Function(node.with(name: Names.prelude_name("#{module}::#{node.name}"))))
        end

      _ -> kept = kept
    end
  end

  if kept.size != functions.size
    return error(problem(file, "CHECK-UNKNOWN-NAME", "the prelude file lacks a function the catalog names"))
  end

  return ok(
    Linker.LinkedModule(
      key: "std/prelude/#{module}.agc",
      file: file,
      name: file,
      prefix: Names.prelude_name("#{module}::"),
      first_id: first_id,
      next_id: Ast.next_free_id(program),
      text: text,
      declarations: kept,
      aliases: {},
      named: {},
      parsed: program,
      watched: [],
      blank_line_after_end: false,
    ),
  )
end

def read(settings: Env.Settings, key: String, file: String) -> Result[String]
  case Resolve.read_source(settings, key)
    SourceFile.Read.Text(text) -> return ok(text)
    SourceFile.Read.Invalid(at) -> return error(staged(file, SourceFile.invalid_utf8(at)))
    SourceFile.Read.Unreadable(_) -> return error(problem(file, "CHECK-IMPORT-IO", "cannot read the prelude file"))
  end
end

def parse(file: String, text: String, first_id: Int) -> Result[Ast.Program]
  case Lexer.lex(text)
    Diag.Outcome.Failed(found) -> return error(staged(file, found))
    Diag.Outcome.Done(tokens) ->
      case Parser.parse(tokens, first_id)
        Diag.Outcome.Failed(found) -> return error(staged(file, found))
        Diag.Outcome.Done(program) -> return ok(program)
      end
  end
end

# A problem of the lexer or the parser in a prelude file.
def staged(file: String, found: Diag.Diagnostic) -> String
  return Failure.pack(Failure.problem(file, "", found.code, found.message, found.span, found.help))
end

def problem(file: String, code: String, message: String) -> String
  start = Source.Position(offset: 0, line: 1, column: 1)
  span = Source.Span(start: start, stop: start)
  return Failure.pack(Failure.problem(file, "", code, message, span, Diag.Help.NoHelp))
end
