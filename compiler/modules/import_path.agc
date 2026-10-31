## The import path rules that need no file system: the module file name, the std/ and pkg/ path
## check, and the path helpers.

import Diag from "../diagnostics/diagnostic"
import Ast from "../syntax/ast"
import {PRELUDE_PREFIX} from "../syntax/prelude_name"
import Unicode from "../syntax/unicode"
import Declarations from "declarations"
import Failure from "link_failure"
import Workspace from "workspace"

## The text after the last "/" of a path.
export def last_part(text: String) -> String
  parts = text.split("/")
  return parts[parts.size - 1]
end

## The folder of a file path: everything before the last "/" (empty for a name alone, "/" for a file in the root
## folder).
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

  return "#{base}/#{rest}"
end

## Whether a path starts at "/", an absolute Windows drive path or a UNC share. A drive needs an ASCII letter,
## a colon and a separator: "C:" and "C:file" depend on a working directory and are not absolute paths.
export def rooted?(path: String) -> Bool
  if path.starts_with?("/") or path.starts_with?("\\\\")
    return true
  end

  if path.length < 3
    return false
  end

  drive = String.code(path.at(0))
  separator = path.at(2)
  letter = (drive >= 65 and drive <= 90) or (drive >= 97 and drive <= 122)
  return letter and path.at(1) == ":" and (separator == "/" or separator == "\\")
end

## A root that does not depend on the working directory. Elsewhere it starts with "/". On Windows it is a drive path
## (C:\ or C:/), a UNC path (\\server\share) or a path from the root of the current drive (/ or \); "C:libs" is
## relative.
export def absolute?(path: String, on_windows: Bool) -> Bool
  if on_windows
    return path.starts_with?("\\") or rooted?(path)
  end

  return path.starts_with?("/")
end

## The path a file is stored under in the program and in the .agcb, and printed by the text forms. root_dir is the
## folder of the root file. A file inside it is its path from there, with no "./"; a file above it keeps the ".." parts
## ("../shared/x.agc"); a std/NAME.agc key is unchanged, and a user file under a std/ folder is "./std/NAME.agc". The
## bytes of an .agcb then do not depend on where the project lives.
export def stored_name(root_dir: String, file: String) -> String
  if root_dir == "" or !rooted?(file)
    return file
  end

  from = path_parts(root_dir)
  to = path_parts(file)
  shared = 0
  while shared < from.size and shared < to.size and from[shared] == to[shared]
    shared = shared + 1
  end

  out: List[String] = []
  for index in shared...from.size
    out = out.push("..")
  end

  for index in shared...to.size
    out = out.push(to[index])
  end

  stored = out.join("/")
  # A user file under a std/ folder must not look like a standard module (the VM puts --source-root before every name
  # but those).
  if stored.starts_with?("std/")
    return "./#{stored}"
  end

  return stored
end

## The stored name of the file of a failure. The root file of a failure is the path as given (Path.resolve keeps
## links), so it is made canonical first, as the key of a loaded file is.
export def stored_file(workspace: Workspace.Workspace, root_dir: String, file: String) -> String
  if file.starts_with?("std/") or file.starts_with?(PRELUDE_PREFIX)
    return file
  end

  real = workspace.real_path.call(file)
  if real.ok?
    return stored_name(root_dir, real.unwrap!)
  end

  return stored_name(root_dir, file)
end

## The file an import names: "util" is "util.agc". A path that names a file with an extension, or no module at all, is
## CHECK-IMPORT-PATH with a help that shows the fix, written as the import line of decl (the alias form or the name
## list).
export def module_file(decl: Ast.ImportDecl, site: Failure.Site) -> Result[String]
  path = decl.path
  stem = ""
  has_stem = path.ends_with?(".agc")
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
  elsif last_part(path) == "" or last_part(path) == "." or last_part(path) == ".."
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

  return error(
    refuse(
      site,
      "a module file name has no dot apart from .agc",
      "rename the file so its name has no dot apart from .agc",
    ),
  )
end

## CHECK-IMPORT-PATH unless a std/ or pkg/ path is made of plain parts: no backslash, no empty, "." or ".." part, and
## no ":" in a part.
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

## The std/ path that a relative import of a std/ module names: `path` is the folder of the importing module (a key,
## with its trailing "/") and the import path. A ".." goes up inside std/ and may not leave it. CHECK-IMPORT-PATH for a
## path that leaves std/ or is not made of plain parts (validate_library_path).
export def inside_std(path: String, site: Failure.Site) -> Result[String]
  kept: List[String] = []
  for part in path.split("/")
    if part == ".." and kept.size > 1
      kept = kept.take(kept.size - 1)
    elsif part == ".."
      return error(invalid_library_path(site))
    else
      kept = kept.push(part)
    end
  end

  named = kept.join("/")
  try validate_library_path(named, site)
  return ok(named)
end

## The parts of a canonical path, with no empty part.
export def path_parts(path: String) -> List[String]
  return path.split("/").filter do |part| part != "" end
end

## The parts of a path, with the "." and ".." parts folded in as text: a ".." removes the part before it, and one at
## the start is dropped. Joined with "/" they only serve to compare with inside?.
export def folded(path: String) -> String
  kept: List[String] = []
  for part in path_parts(path)
    if part == ".."
      kept = kept.take(kept.size - 1)
    elsif part != "."
      kept = kept.push(part)
    end
  end

  return kept.join("/")
end

## True when file is below the folder root: every part of root begins the parts of file.
export def inside?(root: String, file: String) -> Bool
  base = path_parts(root)
  target = path_parts(file)
  if target.size < base.size
    return false
  end

  for index in 0...base.size
    if base[index] != target[index]
      return false
    end
  end

  return true
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

# The path without a final ".ext".
def without_extension(path: String) -> String
  pieces = last_part(path).split(".")
  if pieces.size == 1
    return path
  end

  return path.slice(0, path.length - pieces[pieces.size - 1].length - 1)
end
