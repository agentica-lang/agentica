import Writer from "../../../../compiler/bytecode/bytecode_writer"
import Checker from "../../../../compiler/check/checker"
import SaveFile from "../../../../compiler/io/save_file"
import Env from "../../../../compiler/modules/link_env"
import Linker from "../../../../compiler/modules/linker"
import Lowering from "../../../../compiler/lower/lowering"
import SourceFile from "../../../../compiler/syntax/source_file"
import Workspace from "../../../../compiler/modules/workspace"

# Runs the pure core from a file to the bytes of its .agcb (link, check, lower, write) over a Workspace whose files are
# an in-memory table, then writes the bytes to a file: the only write to the disk. The program imports a sibling
# module, a package from the package cache (pkg/greet/greet, found through the lock and the hash of its files) and a
# std/ module that std_source supplies.
#
# What this proves, and what it does not. The table is keyed under the base folder that the test passes, and the test
# writes garbage files at the same paths of the disk, so a stage that read any of them (with or without a fallback to
# the Workspace) would parse the garbage and fail: dynamic proof for reads. A call that reads nothing, such as
# File.stat with its answer ignored, changes no result: only tests/test_style_core_purity.py, which looks for the
# calls in the source, can see it, and a pure call such as Path.join is invisible to both. A stage that tried the
# Workspace first and the disk after it is not caught either, since the Workspace answers every read.
#
# Arguments, in this order (the test owns the text and the hash of the package, and the version of the binary):
#   base     the folder of the tree; with `windows` a drive path (C:/mem)
#   version  the version the .agcb is stamped with, which `run` checks
#   commit   the commit of the package in the lock
#   git      the git URL of the package
#   greet    the text of greet.agc
#   hash     the hash of the package, from tests/package_support.package_hash
#   out      the file the bytes are written to
#   windows  (optional) the paths are drive paths and Env.windows is true, so the cache folder of the packages is the
#            one under %LOCALAPPDATA%
#
# It prints "ok", or the code and file of the first problem of a stage.

SAVE_TIMEOUT_MS = 10000

MAIN = <<~SRC
  import Greet from "pkg/greet/greet"
  import Mini from "std/mini"
  import Util from "util"

  def main() -> Void
    puts(Greet.hello(Util.twice(Mini.cap(9, 5)).to_s))
  end
SRC

UTIL = <<~SRC
  export def twice(n: Int) -> Int
    return n * 2
  end
SRC

MINI = <<~SRC
  export def cap(n: Int, high: Int) -> Int
    if n > high
      return high
    end
    return n
  end
SRC

# What the test passes in.
struct Given
  base: String
  version: String
  commit: String
  git: String
  greet: String
  hash: String
  out: String
  windows: Bool
end

# The tree of the project, and the package cache where Env says it is: the XDG folder, or the Windows one.
def files_of(given: Given) -> Map[String, String]
  base = given.base
  pkg_root = "#{base}/cache/agentica/pkg"
  if given.windows
    pkg_root = "#{base}/cache/agentica/cache/pkg"
  end
  manifest = <<~TOML
    name = "app"

    [dependencies]
    greet = { git = "#{given.git}", tag = "v1.0.0" }
  TOML
  lock = <<~TOML
    version = 1

    [[package]]
    name = "greet"
    git = "#{given.git}"
    tag = "v1.0.0"
    commit = "#{given.commit}"
    hash = "#{given.hash}"
  TOML
  return {
    "#{base}/project/src/main.agc": MAIN,
    "#{base}/project/src/util.agc": UTIL,
    "#{base}/project/agentica.toml": manifest,
    "#{base}/project/agentica.lock": lock,
    "#{pkg_root}/#{cache_path(given.git)}/#{given.commit}/greet.agc": given.greet,
  }
end

# The part of the cache path of a git URL: host/owner/repo, with no scheme and no .git.
def cache_path(git: String) -> String
  rest = git.slice("https://".length, git.length - "https://".length)
  if rest.ends_with?(".git")
    return rest.slice(0, rest.length - ".git".length)
  end
  return rest
end

def in_memory(files: Map[String, String]) -> Workspace.Workspace
  return Workspace.Workspace(
    read_text: reader() do |path: String| read_file(files, path) end,
    file_exists: predicate() do |path: String| files.has_key?(path) end,
    directory_exists: predicate() do |path: String| folder?(files, path) end,
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

def predicate(f: Fn[String, Bool]) -> Fn[String, Bool]
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

# The names directly inside a folder: a name with more path after it is a folder. A path with a trailing "/" is not a
# folder here, as the Workspace contract says.
def entries(files: Map[String, String], path: String) -> Result[List[Workspace.Entry]]
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
  args = System.args()
  given = Given(
    base: args[0],
    version: args[1],
    commit: args[2],
    git: args[3],
    greet: args[4],
    hash: args[5],
    out: args[6],
    windows: args.size > 7 and args[7] == "windows",
  )
  env = Env.Env(
    agentica_path: "",
    xdg_data_home: "",
    xdg_cache_home: "#{given.base}/cache",
    home: "",
    local_app_data: "",
    windows: false,
  )
  if given.windows
    env = env.with(xdg_cache_home: "", local_app_data: "#{given.base}/cache", windows: true)
  end
  settings = Env.embedded_settings(in_memory(files_of(given)), env, given.version, false)
  puts(compile("#{given.base}/project/src/main.agc", given.out, settings))
end

# "ok" once the bytes are written, or the first problem of a stage.
def compile(path: String, out: String, settings: Env.Settings) -> String
  case Linker.link_file(path, settings)
    Linker.Linking.Failed(failure) -> return "LINK #{failure.diagnostic.code} #{failure.file}"
    Linker.Linking.Done(linked) ->
      case Checker.check(linked, settings)
        Checker.Checking.Failed(problem) -> return "CHECK #{problem.code} #{problem.file}"
        Checker.Checking.Done(checked) -> return lower(linked, checked, out, settings)
      end
  end
end

def lower(linked: Linker.Linked, checked: Checker.Checked, out: String, settings: Env.Settings) -> String
  case Lowering.lower(linked, checked)
    Lowering.Lowered.Failed(problem) -> return "LOWER #{problem.code} #{problem.file}"
    Lowering.Lowered.Done(program) ->
      case Writer.write(program, settings.version)
        Writer.Written.Failed(problem) -> return "WRITE #{problem.code} #{problem.file}"
        Writer.Written.Done(bytes) -> return save(bytes, out)
      end
  end
end

def save(bytes: List[Int], out: String) -> String
  saved = SaveFile.bytes(out, bytes, SAVE_TIMEOUT_MS)
  if saved.ok?
    return "ok"
  end
  return "SAVE #{saved.message}"
end
