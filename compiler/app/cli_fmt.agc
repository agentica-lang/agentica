## What `agentica fmt` says (docs/future/47-formatter.md): the usage line, the settings of a file and what the
## formatter makes of one file. Reading and writing the files and printing is cli.agc's, which owns the output.
##
## `fmt [PATH...]` rewrites the files that formatting changes, `fmt --check [PATH...]` lists them, one per line, and
## gives 1 when there are any, `fmt -` formats the standard input to the standard output, and `fmt --tree FILE` prints
## the normal form of 47.7, which the tests compare before and after formatting. A file that does not parse prints its
## diagnostic, is left as it is and gives 1. A mistake in the call (an unknown option, a path that names no `.agc`
## file) is FMT-USAGE and gives 2.
##
## The settings come from the `[style]` of the nearest agentica.toml, going up from the folder of the file (or of the
## working folder, for `fmt -`): `max_line_width` is the width (Format.WIDTH when it sets none) and
## `blank_line_after_end` adds the empty line after every bare `end`.

import Diag from "../diagnostics/diagnostic"
import Format from "../format/format"
import Paths from "../modules/import_path"
import Workspace from "../modules/workspace"
import Manifest from "../packages/manifest"
import Project from "../packages/project"

# The usage line of `fmt`.
USAGE = "usage: agentica fmt [--check] [PATH...]   or   agentica fmt -   or   agentica fmt --tree FILE"

## What formatting one file gives: no change, the changed text, or the diagnostic that refuses it.
export enum Verdict
  Same
  Changed(String)
  Refused(Diag.Diagnostic)
end

## The usage line of `agentica fmt`.
export def usage() -> String
  return USAGE
end

## What formatting `text` as `settings` ask gives. A text whose bytes differ from the output is changed, so a CRLF file
## is.
export def verdict(text: String, settings: Format.Settings) -> Verdict
  case Format.format_text(text, settings)
    Diag.Outcome.Failed(problem) -> return Verdict.Refused(problem)
    Diag.Outcome.Done(output) ->
      if output == text
        return Verdict.Same
      end

      return Verdict.Changed(output)
  end
end

## The normal form of `text`, or the diagnostic of a text that does not parse.
export def tree(text: String) -> Diag.Outcome[String]
  return Format.tree_text(text)
end

## The folder of the agentica.toml whose `[style]` the file or folder `path` follows: the nearest one going up from
## its canonical path, "" when there is none. A file has no agentica.toml of its own, so starting at it is starting at
## its folder.
export def manifest_dir(workspace: Workspace.Workspace, path: String) -> String
  real = workspace.real_path.call(path)
  if real.ok?
    return Project.nearest_manifest(workspace, real.unwrap!)
  end

  return ""
end

## The settings of the files that follow the manifest in the folder `found` ("" for none: the default settings). A
## manifest that cannot be read or has a bad value is a packed failure, PKG-MANIFEST-INVALID.
export def settings_of(workspace: Workspace.Workspace, found: String) -> Result[Format.Settings]
  if found == ""
    return ok(Format.default_settings())
  end

  manifest = try Manifest.read(workspace, Paths.join(found, Project.MANIFEST_FILE))
  width = Format.WIDTH
  if manifest.max_line_width > 0
    width = manifest.max_line_width
  end

  return ok(Format.Settings(width: width, blank_line_after_end: manifest.blank_line_after_end))
end
