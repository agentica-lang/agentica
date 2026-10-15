## The text form of a link, for tests. See link.agc.

import Paths from "import_path"
import Env from "link_env"
import Failure from "link_failure"
import Linker from "linker"
import ParseText from "parse_text"
import Text from "text"

## The text form of linking the file at path: the linked program, or the ERROR line of the first failure. The first
## line is `program #id span`, the root's module doc as ` module-doc="..."`. Each file that declares something follows
## as `module "path"`, with its declarations (without export, names linked) one level deeper, in the node text form of
## parse_text with ids that start at 0 inside the file. The path is the stored name of the file (Paths.stored_name):
## relative to the folder of the root file, with `..` parts above it, or std/NAME.agc. A failure is the lexer's ERROR
## line with ` file="path"` added. tests/frontend-modules-common.rkt prints the same text from the Racket program.
export def link_text(path: String, settings: Env.Settings) -> String
  case Linker.link_file(path, settings)
    Linker.Linking.Done(linked) -> return program_lines(linked, {}).join("\n")
    Linker.Linking.Failed(failure) -> return failure_text(root_dir_of(path), failure)
  end
end

## The ids of the files of a link, one line per file in the order they were read, including the files that declare
## nothing: `module "path" first=N next=N` (the file's nodes are numbered N up to, not including, the next). A failure
## prints as link_text does.
export def ids_text(path: String, settings: Env.Settings) -> String
  case Linker.link_file(path, settings)
    Linker.Linking.Done(linked) ->
      lines = linked.modules.map do |module|
        "module " + Text.quote(module.name) + " first=" + module.first_id.to_s + " next=" + module.next_id.to_s
      end
      return lines.join("\n")
    Linker.Linking.Failed(failure) -> return failure_text(root_dir_of(path), failure)
  end
end

# The folder of the canonical root file, "" when the file cannot be resolved.
export def root_dir_of(path: String) -> String
  real = Path.real(path)
  if real.ok?
    return Paths.directory_of(real.unwrap!)
  end
  return ""
end

## The stored name of the file of a failure. The root file of a failure is the path as given (Path.resolve keeps
## links), so it is made canonical first, as the key of a loaded file is.
export def stored(root_dir: String, file: String) -> String
  if file.starts_with?("std/")
    return file
  end
  real = Path.real(file)
  if real.ok?
    return Paths.stored_name(root_dir, real.unwrap!)
  end
  return Paths.stored_name(root_dir, file)
end

## The ERROR line of a link failure, with the file it is in.
export def failure_text(root_dir: String, failure: Failure.Failure) -> String
  return Text.diagnostic_line(failure.diagnostic) + " file=" + Text.quote(stored(root_dir, failure.file))
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
  lines = out.push("  module " + Text.quote(module.name))
  at = ParseText.Margin(indent: "    ", base: module.first_id, notes: notes)
  for decl in module.declarations
    lines = ParseText.print_decl(lines, at, "declaration", decl)
  end
  return lines
end
