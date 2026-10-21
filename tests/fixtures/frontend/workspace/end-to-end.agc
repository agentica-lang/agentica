import Writer from "../../../../compiler/bytecode/bytecode_writer"
import Checker from "../../../../compiler/check/checker"
import Env from "../../../../compiler/modules/link_env"
import Linker from "../../../../compiler/modules/linker"
import Lowering from "../../../../compiler/lower/lowering"
import SourceFile from "../../../../compiler/syntax/source_file"
import Workspace from "../../../../compiler/modules/workspace"

# Runs the pure core from a file to the bytes of its .agcb (link, check, lower, write) over a Workspace whose files are
# an in-memory table, so no file of the disk is read: a stage that reached the machine instead of the Workspace would
# fail on a path that exists nowhere. The program imports a sibling module, a package from the package cache
# (pkg/greet/greet, found through the lock and the hash of its files) and a std/ module that std_source supplies.
#
# With the argument `windows`, the paths are drive paths and Env.windows is true, so the cache folder of the packages
# is the one under %LOCALAPPDATA%. It prints the stored names of the linked files, each with whether the bytes hold it,
# or the code and file of the first problem of a stage.

COMMIT = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

# The hash that tests/package_support.package_hash gives for GREET (a second implementation of the hash rule).
GREET_HASH = "sha256:26a7e161b772135bd4ae851cc1e47a0038d87576856325f8eb09f6f86fdff0bf"

MAIN = (
  "import Greet from \"pkg/greet/greet\"\nimport Mini from \"std/mini\"\nimport Util from \"util\"\n\n" +
  "def main() -> Void\n  puts(Greet.hello(Util.twice(Mini.cap(9, 5)).to_s))\nend\n"
)

UTIL = "export def twice(n: Int) -> Int\n  return n * 2\nend\n"

GREET = "export def hello(name: String) -> String\n  return \"hello \" + name\nend\n"

MINI = "export def cap(n: Int, high: Int) -> Int\n  if n > high\n    return high\n  end\n  return n\nend\n"

GIT = "https://github.com/acme/greet.git"

MANIFEST = "name = \"app\"\n\n[dependencies]\ngreet = { git = \"#{GIT}\", tag = \"v1.0.0\" }\n"

# The tree of the project, and the package cache where Env says it is: the XDG folder, or the Windows one.
def files_of(base: String, windows: Bool) -> Map[String, String]
  pkg_root = "#{base}/cache/agentica/pkg"
  if windows
    pkg_root = "#{base}/cache/agentica/cache/pkg"
  end
  lock = (
    "version = 1\n\n[[package]]\nname = \"greet\"\ngit = \"#{GIT}\"\n" +
    "tag = \"v1.0.0\"\ncommit = \"#{COMMIT}\"\nhash = \"#{GREET_HASH}\"\n"
  )
  return {
    "#{base}/project/src/main.agc": MAIN,
    "#{base}/project/src/util.agc": UTIL,
    "#{base}/project/agentica.toml": MANIFEST,
    "#{base}/project/agentica.lock": lock,
    "#{pkg_root}/github.com/acme/greet/#{COMMIT}/greet.agc": GREET,
  }
end

def in_memory(files: Map[String, String]) -> Workspace.Workspace
  return Workspace.Workspace(
    read_text: reader() do |path: String| read_file(files, path) end,
    file_exists: check() do |path: String| files.has_key?(path) end,
    directory_exists: check() do |path: String| folder?(files, path) end,
    real_path: resolver() do |path: String| ok(path) end,
    resolve_path: resolver() do |path: String| ok(path) end,
    std_source: resolver() do |name: String| std_module(name) end,
    list_folder: lister() do |path: String| entries(files, path) end,
    read_bytes: byter() do |path: String| bytes_of(files, path) end,
  )
end

# The identity of a function value: a block can only be written as the block of a call.
def reader(f: Fn[String, SourceFile.Read]) -> Fn[String, SourceFile.Read]
  return f
end

def check(f: Fn[String, Bool]) -> Fn[String, Bool]
  return f
end

def resolver(f: Fn[String, Result[String]]) -> Fn[String, Result[String]]
  return f
end

def lister(f: Fn[String, Result[List[Workspace.Entry]]]) -> Fn[String, Result[List[Workspace.Entry]]]
  return f
end

def byter(f: Fn[String, Result[List[Int]]]) -> Fn[String, Result[List[Int]]]
  return f
end

def read_file(files: Map[String, String], path: String) -> SourceFile.Read
  if files.has_key?(path)
    return SourceFile.Read.Text(files[path])
  end
  return SourceFile.Read.Unreadable("no such file")
end

def bytes_of(files: Map[String, String], path: String) -> Result[List[Int]]
  if files.has_key?(path)
    return ok(String.to_bytes(files[path]))
  end
  return error("no such file")
end

def std_module(name: String) -> Result[String]
  if name == "mini.agc"
    return ok(MINI)
  end
  return error("no embedded source #{name}")
end

def folder?(files: Map[String, String], path: String) -> Bool
  return files.keys.any? do |file: String| file.starts_with?("#{path}/") end
end

# The names directly inside a folder: a name with more path after it is a folder. The package hash lists the folder of
# the package as "<root>/", with the "/" it gets from joining an empty name, and a disk accepts that.
def entries(files: Map[String, String], listed: String) -> Result[List[Workspace.Entry]]
  path = listed
  if path.ends_with?("/")
    path = path.slice(0, path.length - 1)
  end
  if !folder?(files, path)
    return error("no such folder")
  end
  found: Map[String, Workspace.EntryKind] = {}
  for file in files.keys
    if file.starts_with?("#{path}/")
      rest = file.slice(path.length + 1, file.length - path.length - 1).split("/")
      kind = Workspace.EntryKind.Directory
      if rest.size == 1
        kind = Workspace.EntryKind.File
      end
      found = found.put(rest[0], kind)
    end
  end
  return ok(found.keys.map do |name: String| Workspace.Entry(name: name, kind: found[name]) end)
end

def main() -> Void
  windows = System.args().any? do |argument: String| argument == "windows" end
  base = "/mem"
  env = Env.Env(
    agentica_path: "",
    xdg_data_home: "",
    xdg_cache_home: "#{base}/cache",
    home: "",
    local_app_data: "",
    windows: false,
  )
  if windows
    base = "C:/mem"
    env = env.with(xdg_cache_home: "", local_app_data: "#{base}/cache", windows: true)
  end
  workspace = in_memory(files_of(base, windows))
  settings = Env.embedded_settings(workspace, env, "0.0.0", false)
  puts(compile("#{base}/project/src/main.agc", settings))
end

# The stored names of the linked files, then for each whether the .agcb holds it; or the first problem of a stage.
def compile(path: String, settings: Env.Settings) -> String
  case Linker.link_file(path, settings)
    Linker.Linking.Failed(failure) -> return "LINK #{failure.diagnostic.code} #{failure.file}"
    Linker.Linking.Done(linked) ->
      case Checker.check(linked, settings)
        Checker.Checking.Failed(problem) -> return "CHECK #{problem.code} #{problem.file}"
        Checker.Checking.Done(checked) -> return lower(linked, checked, settings)
      end
  end
end

def lower(linked: Linker.Linked, checked: Checker.Checked, settings: Env.Settings) -> String
  case Lowering.lower(linked, checked)
    Lowering.Lowered.Failed(problem) -> return "LOWER #{problem.code} #{problem.file}"
    Lowering.Lowered.Done(program) ->
      case Writer.write(program, settings.version)
        Writer.Written.Failed(problem) -> return "WRITE #{problem.code} #{problem.file}"
        Writer.Written.Done(bytes) -> return report(linked, bytes)
      end
  end
end

def report(linked: Linker.Linked, bytes: List[Int]) -> String
  names = linked.modules.map do |module: Linker.LinkedModule| module.name end.sort
  lines = names.map do |name: String| "#{name} in-bytes=#{holds?(bytes, String.to_bytes(name))}" end
  return lines.join("\n")
end

# Whether the bytes hold the piece, as a run of bytes (the stored names are written as they are in the .agcb).
def holds?(bytes: List[Int], piece: List[Int]) -> Bool
  for start in 0..(bytes.size - piece.size)
    if run_at?(bytes, start, piece)
      return true
    end
  end
  return false
end

def run_at?(bytes: List[Int], start: Int, piece: List[Int]) -> Bool
  for offset in 0...piece.size
    if bytes[start + offset] != piece[offset]
      return false
    end
  end
  return true
end
