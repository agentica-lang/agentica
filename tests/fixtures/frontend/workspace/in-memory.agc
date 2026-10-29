import Env from "../../../../compiler/modules/link_env"
import LinkText from "../../../../compiler/modules/link_text"
import SourceFile from "../../../../compiler/syntax/source_file"
import Workspace from "../../../../compiler/modules/workspace"

# Links programs through a Workspace whose files are an in-memory table, so no file of the disk is read: the proof
# that the core reaches the machine only through the Workspace record (modules/workspace.agc). Prints the id ranges of
# the link of each root, then the failure of a root whose import is missing.

FILES = {
  "/mem/root.agc": "import Util from \"util\"\n\ndef main() -> Void\n  puts(Util.twice(2).to_s)\nend\n",
  "/mem/util.agc": "export def twice(n: Int) -> Int\n  return n * 2\nend\n",
  "/mem/broken.agc": "import Missing from \"missing\"\n\ndef main() -> Void\nend\n",
}

def read_text(path: String) -> SourceFile.Read
  if FILES.has_key?(path)
    return SourceFile.Read.Text(FILES[path])
  end
  return SourceFile.Read.Unreadable("no such file")
end

def file_exists(path: String) -> Bool
  return FILES.has_key?(path)
end

def directory_exists(path: String) -> Bool
  return path == "/mem"
end

def same_path(path: String) -> Result[String]
  return ok(path)
end

def nothing(name: String) -> Result[String]
  return error("no embedded source #{name}")
end

def no_folder(path: String) -> Result[List[Workspace.Entry]]
  return error("no such folder")
end

def no_bytes(path: String) -> Result[Bytes]
  return error("no such file")
end

def no_native(request: Workspace.NativeRequest) -> Result[String]
  return error("no native artifact in this workspace")
end

def main() -> Void
  workspace = Workspace.Workspace(
    read_text: &read_text,
    file_exists: &file_exists,
    directory_exists: &directory_exists,
    real_path: &same_path,
    resolve_path: &same_path,
    std_source: &nothing,
    list_folder: &no_folder,
    read_bytes: &no_bytes,
    native_artifact: &no_native,
    check_cache: Workspace.no_check_cache(),
  )
  env = Env.Env(agentica_path: "", xdg_data_home: "", xdg_cache_home: "", home: "", local_app_data: "", windows: false, os: "linux")
  settings = Env.settings(workspace, "stdlib", env)
  puts(LinkText.ids_text("/mem/root.agc", settings))
  puts(LinkText.ids_text("/mem/broken.agc", settings))
end
