## The text form of a link, for tests. See link.agc.

import "import_path" as Paths
import "link_env" as Env
import "link_failure" as Failure
import "linker" as Linker
import "parse_text" as ParseText
import "text" as Text

## The text form of linking the file at path: the linked program, or the ERROR line of the first failure. The first line is `program #id span`, the root's module doc as ` module-doc="..."`. Each file that declares something follows as `module "path"`, with its declarations (without export, names linked) one level deeper, in the node text form of parse_text with ids that start at 0 inside the file. The path is relative to the folder of the root file, or absolute outside it, or std/NAME.agc. A failure is the lexer's ERROR line with ` file="path"` added. tests/frontend-modules-common.rkt prints the same text from the Racket program.
export def link_text(path: String, settings: Env.Settings) -> String
  case Linker.link_file(path, settings)
    Linker.Linking.Done(linked) -> return program_lines(linked, {}).join("\n")
    Linker.Linking.Failed(failure) -> return failure_text(root_dir_of(path), failure)
  end
end

## The ids of the files of a link, one line per file in the order they were read, including the files that declare nothing: `module "path" first=N next=N` (the file's nodes are numbered N up to, not including, the next). A failure prints as link_text does.
export def ids_text(path: String, settings: Env.Settings) -> String
  case Linker.link_file(path, settings)
    Linker.Linking.Done(linked) ->
      lines = linked.modules.map do |module| "module " + Text.quote(display(linked.root_dir, module.file)) + " first=" + module.first_id.to_s + " next=" + module.next_id.to_s end
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

## The path of a file as the text forms print it: relative to the folder of the root file when it is inside.
export def display(root_dir: String, file: String) -> String
  prefix = Paths.join(root_dir, "")
  if root_dir != "" and file.starts_with?(prefix)
    return file.slice(prefix.length, file.length - prefix.length)
  end
  return file
end

## The ERROR line of a link failure, with the file it is in.
export def failure_text(root_dir: String, failure: Failure.Failure) -> String
  return Text.diagnostic_line(failure.diagnostic) + " file=" + Text.quote(display(root_dir, failure.file))
end

## The lines of the linked program. notes is the text added to the line of a node, by id (see ParseText.Margin).
export def program_lines(linked: Linker.Linked, notes: Map[Int, String]) -> List[String]
  root = linked.root
  lines: List[String] = [ParseText.head(ParseText.Margin(indent: "", base: 0, notes: notes), "", "program", root.id, root.span, ParseText.text_attr(" module-doc=", root.module_doc))]
  for module in linked.modules
    if module.declarations.size > 0
      lines = module_lines(lines, linked.root_dir, module, notes)
    end
  end
  return lines
end

def module_lines(out: List[String], root_dir: String, module: Linker.LinkedModule, notes: Map[Int, String]) -> List[String]
  lines = out.push("  module " + Text.quote(display(root_dir, module.file)))
  at = ParseText.Margin(indent: "    ", base: module.first_id, notes: notes)
  for decl in module.declarations
    lines = ParseText.print_decl(lines, at, "declaration", decl)
  end
  return lines
end
