## The file an import names, and the CHECK-IMPORT-PATH failures that show the import line to write.

import Ast from "../syntax/ast"
import Unicode from "../syntax/unicode"
import Declarations from "declarations"
import Paths from "import_path"
import Failure from "link_failure"

## The file an import names: "util" is "util.agc". A path that names a file with an extension, or no module at all, is
## CHECK-IMPORT-PATH with a help that shows the fix, written as the import line of decl (the alias form or the name
## list).
def module_file(decl: Ast.ImportDecl, site: Failure.Site) -> Result[String]
  path = decl.path
  stem = ""
  has_stem = path.end_with?(".agc")
  if has_stem
    stem = path.slice(0, path.length - 4)
  end

  guess = without_extension(path)
  if module_name?(path)
    return ok("#{path}.agc")
  elsif has_stem and module_name?(stem)
    return error(
      refuse(
        site,
        "import paths name a module without the .agc extension",
        "write #{Declarations.import_line(Unicode.written_text(stem), decl)}",
      ),
    )
  elsif Paths.last_part(path) == "" or Paths.last_part(path) == "." or Paths.last_part(path) == ".."
    return error(
      refuse(
        site,
        "import paths name a module file",
        "write #{Declarations.import_line("\"models\"", decl)} to load models.agc",
      ),
    )
  elsif module_name?(guess)
    return error(
      refuse(
        site,
        "import paths name a module without an extension",
        "write #{Declarations.import_line(Unicode.written_text(guess), decl)} to load #{guess}.agc",
      ),
    )
  end

  error(
    refuse(
      site,
      "a module file name has no dot apart from .agc",
      "rename the file so its name has no dot apart from .agc",
    ),
  )
end

private

def refuse(site: Failure.Site, message: String, help: String) -> String
  Failure.fail_at(site, "CHECK-IMPORT-PATH", message, Failure.hint(help))
end

# A name has text and no dot: "models" is a module name, "models.rb" is not.
def module_name?(text: String) -> Bool
  name = Paths.last_part(text)
  name != "" and !name.include?(".")
end

# The path without a final ".ext".
def without_extension(path: String) -> String
  pieces = Paths.last_part(path).split(".")
  return path if pieces.size == 1

  path.slice(0, path.length - pieces[pieces.size - 1].length - 1)
end
