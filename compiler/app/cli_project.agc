## What the package commands (`install`, `add`, `update`) share: they work on the project of the working folder, found
## as a build finds it, and answer with the lines of what they did (or `{"ok":true}` with `--json`), or with the first
## failure, a packed failure of the PKG- codes.

import Front from "../analysis/front"
import Paths from "../modules/import_path"
import Failure from "../modules/link_failure"
import Workspace from "../modules/workspace"
import Reply from "cli_reply"

# The manifest the commands look for, as in packages/project.agc.
MANIFEST_FILE = "agentica.toml"

## Runs `work` in the working folder (a canonical path). Its text is the answer; `style` is the output style of the
## options: with `json` a success prints `{"ok":true}`, as `check` does.
export def run(style: String, workspace: Workspace.Workspace, work: Fn[String, Result[String]]) -> Reply.Answer
  cwd = Path.cwd()
  if !cwd.ok?
    return Reply.Answer.Printed(Reply.failed(2, "agentica: cannot read the working folder\n"))
  end
  real = workspace.real_path.call(cwd.unwrap!)
  dir = cwd.unwrap!
  if real.ok?
    dir = real.unwrap!
  end
  done = work.call(dir)
  if !done.ok?
    return Reply.Answer.Rejected(Front.link_problem(Failure.unpack_failure(done.message)))
  end
  if style == "json"
    return Reply.Answer.Printed(Reply.printed("{\"ok\":true}\n"))
  end
  return Reply.Answer.Printed(Reply.printed(done.unwrap!))
end

## The failure for a working folder with no manifest above it.
export def missing_manifest(dir: String) -> String
  file = Paths.join(dir, MANIFEST_FILE)
  message = "there is no #{MANIFEST_FILE} in this folder or above"
  help = Failure.hint("write #{MANIFEST_FILE} in the folder of the project, with a [dependencies] table")
  return Failure.fail_file(file, "PKG-MANIFEST-MISSING", message, help)
end
