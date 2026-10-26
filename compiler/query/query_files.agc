## The one file a query command reads, and the name it answers with (docs/future/39-semantic-cli.md, 39.4). Everything
## goes through the Workspace of the settings, so a test or `--stdin` can stand in for the disk.
##
## The file is the word of the command line or, with `--stdin FILE`, that FILE. A `std/` name (`std/queue`) is a module
## of the standard library, read from the provider of the settings with the checks an import gets; with `--stdin` the
## name is a path of the disk instead, since the buffer stands for a file of the disk.

import Problems from "../diagnostics/problem"
import Paths from "../modules/import_path"
import Env from "../modules/link_env"
import Failure from "../modules/link_failure"
import Resolve from "../modules/resolve_import"
import Source from "../syntax/source"
import SourceFile from "../syntax/source_file"
import QueryOptions from "query_options"

## The file of a command, or why the words do not name exactly one.
export enum Picked
  File(String)
  Refused(Problems.Problem)
end

## The one file `query` names: its only word, or the file of `--stdin` in place of a word. A missing or an extra
## argument is QUERY-USAGE, with `usage` as its help.
export def pick(query: QueryOptions.Query, usage: String) -> Picked
  if query.stdin != ""
    if query.words.size > 0
      return Picked.Refused(QueryOptions.refusal("--stdin FILE stands in for the FILE argument", usage))
    end

    return Picked.File(query.stdin)
  elsif query.words.size == 0 or query.words[0] == ""
    return Picked.Refused(QueryOptions.refusal("missing FILE", usage))
  elsif query.words.size > 1
    return Picked.Refused(QueryOptions.refusal("extra argument #{query.words[1]}", usage))
  end

  return Picked.File(query.words[0])
end

## The text of `file`. `buffered` is true when the Workspace holds the standard input as that file.
export def read(settings: Env.Settings, file: String, buffered: Bool) -> SourceFile.Read
  if embedded?(file, buffered)
    key = std_key(file)
    here = Source.Position(offset: 0, line: 1, column: 1)
    site = Failure.Site(file: file, span: Source.Span(start: here, stop: here))
    checked = Resolve.standard(settings, key, site)
    if !checked.ok?
      return SourceFile.Read.Unreadable(checked.message)
    end

    return Resolve.read_source(settings, key)
  end

  return settings.workspace.read_text.call(file)
end

## The QUERY-USAGE diagnostic of a file that cannot be read.
export def unreadable(file: String, usage: String) -> Problems.Problem
  return QueryOptions.refusal("cannot read #{file}", usage)
end

## The name an answer gives the file: `std/MOD.agc` for a module of the standard library, otherwise the canonical path,
## made relative to the working folder when the file is below it (a canonical path is the same file under any
## spelling). A file the Workspace cannot resolve keeps the name it was typed with.
export def display(settings: Env.Settings, file: String, buffered: Bool) -> String
  if embedded?(file, buffered)
    return std_key(file)
  end

  real = settings.workspace.real_path.call(file)
  here = settings.workspace.real_path.call(".")
  if !real.ok? or !here.ok?
    return file
  end

  named = real.unwrap!
  base = here.unwrap!
  if settings.env.windows
    named = named.replace("\\", "/")
    base = base.replace("\\", "/")
  end

  if named != base and Paths.inside?(base, named)
    return Paths.stored_name(base, named)
  end

  return real.unwrap!
end

def embedded?(file: String, buffered: Bool) -> Bool
  return !buffered and file.starts_with?("std/")
end

# The key of a module in the provider: the name with its extension.
def std_key(file: String) -> String
  if file.ends_with?(".agc")
    return file
  end

  return "#{file}.agc"
end
