## The import path rules of src/modules.rkt that need no file system: the module file name, the std/ and pkg/ path check, and the path helpers.

import "ast" as Ast
import "declarations" as Declarations
import "diagnostic" as Diag
import "link_failure" as Failure
import "unicode" as Unicode

## The text after the last "/" of a path.
export def last_part(text: String) -> String
  parts = text.split("/")
  return parts[parts.size - 1]
end

## The folder of a file path: everything before the last "/" (empty for a name alone, "/" for a file in the root folder).
export def directory_of(path: String) -> String
  tail = last_part(path).length
  if tail == path.length
    return ""
  end
  if tail + 1 == path.length
    return "/"
  end
  return path.slice(0, path.length - tail - 1)
end

## Two path parts joined by one "/".
export def join(base: String, rest: String) -> String
  if base.ends_with?("/")
    return base + rest
  end
  return base + "/" + rest
end

## The file an import names: "util" is "util.agc". A path that names a file with an extension, or no module at all, is CHECK-IMPORT-PATH with a help that shows the fix, written as the import line of decl (the alias form or the name list).
export def module_file(decl: Ast.ImportDecl, site: Failure.Site) -> Result[String]
  path = decl.path
  stem = ""
  has_stem = path.ends_with?(".agc")
  if has_stem
    stem = path.slice(0, path.length - 4)
  end
  guess = without_extension(path)
  if module_name?(path)
    return ok(path + ".agc")
  elsif has_stem and module_name?(stem)
    return error(refuse(site, "import paths name a module without the .agc extension", "write " + Declarations.import_line(Unicode.written_text(stem), decl)))
  elsif last_part(path) == "" or last_part(path) == "." or last_part(path) == ".."
    return error(refuse(site, "import paths name a module file", "write " + Declarations.import_line("\"models\"", decl) + " to load models.agc"))
  elsif module_name?(guess)
    return error(refuse(site, "import paths name a module without an extension", "write " + Declarations.import_line(Unicode.written_text(guess), decl) + " to load " + guess + ".agc"))
  end
  return error(refuse(site, "a module file name has no dot apart from .agc", "rename the file so its name has no dot apart from .agc"))
end

## CHECK-IMPORT-PATH unless a std/ or pkg/ path is made of plain parts: no backslash, no empty, "." or ".." part, and no ":" in a part.
export def validate_library_path(path: String, site: Failure.Site) -> Result[Void]
  if path.contains?("\\")
    return error(invalid_library_path(site))
  end
  for part in path.split("/")
    if part == "" or part == "." or part == ".." or part.contains?(":")
      return error(invalid_library_path(site))
    end
  end
  return ok()
end

def invalid_library_path(site: Failure.Site) -> String
  return Failure.fail_at(site, "CHECK-IMPORT-PATH", "invalid library path", Diag.Help.NoHelp)
end

def refuse(site: Failure.Site, message: String, help: String) -> String
  return Failure.fail_at(site, "CHECK-IMPORT-PATH", message, Failure.hint(help))
end

# A name has text and no dot: "models" is a module name, "models.rb" is not.
def module_name?(text: String) -> Bool
  name = last_part(text)
  return name != "" and !name.contains?(".")
end

# The path without a final ".ext" (the regexp [.][^./]*$ of src/modules.rkt).
def without_extension(path: String) -> String
  pieces = last_part(path).split(".")
  if pieces.size == 1
    return path
  end
  return path.slice(0, path.length - pieces[pieces.size - 1].length - 1)
end
