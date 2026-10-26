## The text form of a link, for tests. See link.agc.

import ParseText from "../syntax/parse_text"
import Text from "../syntax/text"
import Paths from "import_path"
import Env from "link_env"
import Failure from "link_failure"
import Linker from "linker"
import Workspace from "workspace"

## The text form of linking the file at path: the linked program, or the ERROR line of the first failure. The first
## line is `program #id span`, the root's module doc as ` module-doc="..."`. Each file that declares something follows
## as `module "path"`, with its declarations (without export, names linked) one level deeper, in the node text form of
## parse_text with ids that start at 0 inside the file. The path is the stored name of the file (Paths.stored_name):
## relative to the folder of the root file, with `..` parts above it, or std/NAME.agc. A failure is the lexer's ERROR
## line with ` file="path"` added, and ` key="path"` for a failure at a key of agentica.toml or agentica.lock. The
## goldens are in tests/fixtures/frontend/modules/.
export def link_text(path: String, settings: Env.Settings) -> String
  case Linker.link_file(path, settings)
    Linker.Linking.Done(linked) -> return program_lines(linked, {}).join("\n")
    Linker.Linking.Failed(failure) -> return root_failure_text(settings.workspace, path, failure)
  end
end

## The ids of the files of a link, one line per file in the order they were read, including the files that declare
## nothing: `module "path" first=N next=N` (the file's nodes are numbered N up to, not including, the next). A failure
## prints as link_text does.
export def ids_text(path: String, settings: Env.Settings) -> String
  case Linker.link_file(path, settings)
    Linker.Linking.Done(linked) ->
      lines = linked.modules.map do |module|
        "module #{Text.quote(module.name)} first=#{module.first_id} next=#{module.next_id}"
      end

      return lines.join("\n")
    Linker.Linking.Failed(failure) -> return root_failure_text(settings.workspace, path, failure)
  end
end

## The ERROR line of the failure of linking the root file at `path`.
export def root_failure_text(workspace: Workspace.Workspace, path: String, failure: Failure.Failure) -> String
  return failure_text(workspace, root_dir_of(workspace, path), failure)
end

## The ERROR line of a link failure, with the file it is in, and ` key="path"` for a failure at a key of agentica.toml
## or agentica.lock.
export def failure_text(workspace: Workspace.Workspace, root_dir: String, failure: Failure.Failure) -> String
  shown = Text.quote(Paths.stored_file(workspace, root_dir, failure.file))
  line = "#{Text.diagnostic_line(failure.diagnostic)} file=#{shown}"
  if failure.key_path != ""
    return "#{line} key=#{Text.quote(failure.key_path)}"
  end

  return line
end

## The lines of the linked program. notes is the text added to the line of a node, by id (see ParseText.Margin).
export def program_lines(linked: Linker.Linked, notes: Map[Int, String]) -> List[String]
  root = linked.root
  lines: List[String] = [
    ParseText.head(
      ParseText.Margin(indent: "", base: 0, notes: notes),
      "",
      "program",
      root.id,
      root.span,
      ParseText.text_attr(" module-doc=", root.module_doc),
    ),
  ]
  for module in linked.modules
    if module.declarations.size > 0
      lines = module_lines(lines, module, notes)
    end
  end

  return lines
end

def module_lines(out: List[String], module: Linker.LinkedModule, notes: Map[Int, String]) -> List[String]
  lines = out.push("  module #{Text.quote(module.name)}")
  at = ParseText.Margin(indent: "    ", base: module.first_id, notes: notes)
  for decl in module.declarations
    lines = ParseText.print_decl(lines, at, "declaration", decl)
  end

  return lines
end

# The folder of the canonical root file, "" when the file cannot be resolved.
def root_dir_of(workspace: Workspace.Workspace, path: String) -> String
  real = workspace.real_path.call(path)
  if real.ok?
    return Paths.directory_of(real.unwrap!)
  end

  return ""
end
