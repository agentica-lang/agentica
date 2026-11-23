## `agentica init [NAME]` (docs/grammar/05b-modules.md): starts a project in the working folder. It writes
## agentica.toml with the name (by default the name of the folder) and the running version as the `agentica` key, and a
## main.agc that prints a greeting when the folder has none. A folder that has an agentica.toml is left as it is
## (PKG-MANIFEST-EXISTS), and so is a name that the manifest would refuse (PKG-MANIFEST-INVALID at `name`). main.agc is
## written first, so a manifest that cannot be written leaves a folder that `init` can run in again.

import SaveFile from "../io/save_file"
import Paths from "../modules/import_path"
import Env from "../modules/link_env"
import Failure from "../modules/link_failure"
import GitSource from "../packages/git_source"
import Manifest from "../packages/manifest"
import Project from "../packages/project"
import CliProject from "cli_project"
import Reply from "cli_reply"
import Texts from "cli_text"

## Runs `init`. `words` are the ones after the command: none, or the name of the project.
def init(settings: Env.Settings, style: String, words: List[String]) -> Reply.Answer
  # A word that starts with "-" is an option nobody knows, not a name.
  if words.size > 1 or (words.size == 1 and words[0].start_with?("-"))
    return Reply.Answer.Printed(Reply.failed(2, Texts.usage_text()))
  end

  CliProject.run(style, settings.workspace) do |dir: String| start(settings, dir, words) end
end

private

# The deadline of the write of a file, in milliseconds.
WRITE_TIMEOUT_MS = 60_000
MAIN_FILE = "main.agc"
MAIN_TEXT = "def main() -> Void\n  puts(\"Hello, world!\")\nend\n"

def start(settings: Env.Settings, dir: String, words: List[String]) -> Result[String]
  manifest = Paths.join(dir, Project.MANIFEST_FILE)
  if settings.workspace.file_exists.call(manifest)
    message = "#{manifest} exists already"
    help = Failure.hint("`agentica init` starts a project and never changes an agentica.toml")
    return error(Failure.fail_file(manifest, "PKG-MANIFEST-EXISTS", message, help))
  end

  name = folder_name(dir)
  if words.size == 1
    name = words[0]
  end

  problem = GitSource.name_problem(name)
  if problem != ""
    help = Failure.hint("#{problem}; run `agentica init NAME` to choose the name")
    return error(Failure.fail_key(manifest, "name", "PKG-MANIFEST-INVALID", "not a package name", help))
  end

  text = "name = \"#{name}\"\nagentica = \"#{settings.version}\"\n"
  try Manifest.parse(manifest, text)
  lines: List[String] = []
  main = Paths.join(dir, MAIN_FILE)
  if !settings.workspace.file_exists.call(main)
    try save(main, MAIN_TEXT)
    lines = lines.push("created #{MAIN_FILE}")
  end

  try save(manifest, text)
  lines = lines.push("created #{Project.MANIFEST_FILE}")
  ok("#{lines.join("\n")}\n")
end

# The last part of a path, which is the name of the folder; "" for the root.
def folder_name(dir: String) -> String
  parts = dir.replace("\\", "/").split("/").select do |part| part != "" end
  return "" if parts.size == 0

  parts[parts.size - 1]
end

# Writes a new file (SaveFile.replace never replaces one that appeared meanwhile).
def save(file: String, text: String) -> Result[Void]
  written = SaveFile.replace(file, text.bytes, false, WRITE_TIMEOUT_MS)
  return ok() if written.ok?

  error(Failure.fail_file(file, "PKG-WRITE", "cannot write #{file}", Failure.hint(written.message)))
end
