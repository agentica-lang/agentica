## The `--source-root` option of the VM for a program the folder of the program
## as the user should type it, which the VM puts before the stored names it prints, so a runtime trace names a file the
## way a compile-time diagnostic does.

import Paths from "import_path"

## The folder of the file `entry`: relative to the working directory (built from the canonical folder, so the ".."
## names of an imported file stay right through links), or absolute when the entry was typed as an absolute path. It is
## "" when the file is in the working directory, and also when a path cannot be resolved.
export def option(entry: String) -> String
  real = Path.real(entry)
  if !real.ok?
    return ""
  end
  folder = Paths.directory_of(real.unwrap!)
  if entry.starts_with?("/")
    return folder
  end
  here = Path.cwd()
  if !here.ok?
    return ""
  end
  canonical = Path.real(here.unwrap!)
  if !canonical.ok?
    return ""
  end
  return relative(parts(canonical.unwrap!), parts(folder))
end

# The path of `to` from `from`: one ".." for each part of `from` that `to` does not share, then the rest of `to`.
def relative(from: List[String], to: List[String]) -> String
  shared = 0
  while shared < from.size and shared < to.size and from[shared] == to[shared]
    shared += 1
  end
  names: List[String] = []
  for index in shared...from.size
    names = names.push("..")
  end
  for index in shared...to.size
    names = names.push(to[index])
  end
  return names.join("/")
end

def parts(path: String) -> List[String]
  return path.split("/").filter do |part: String| part != "" end
end
