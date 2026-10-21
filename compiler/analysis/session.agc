## What a library client keeps between questions (stdlib/analysis.agc): the settings of the machine and the buffers
## that stand in for files. The value is immutable: `update` and `close` give a new one, and a question reads the one
## it is given, so tasks may share a session and ask it at once. Each question builds its Workspace from the buffers
## and runs the stages; the `generation` counts the changes. The `cache` (cache.agc) holds the roots that `refresh`
## linked and checked and the files it parsed: a question uses what is still valid and computes the rest, so the
## answers are the same with any cache.

import Env from "../modules/link_env"
import Overlay from "../modules/overlay"
import SourceFile from "../syntax/source_file"
import Cache from "cache"
import Front from "front"

## The settings, the buffers, the number of changes made to them and the cache.
export struct Session
  settings: Env.Settings
  buffers: List[Overlay.Buffer]
  generation: Int
  cache: Cache.Cache
end

## A session over the disk of `settings` with the text of each file of `texts` (a path and the text that stands in for
## it).
export def open(settings: Env.Settings, texts: Map[String, String]) -> Session
  session = Session(settings: settings, buffers: [], generation: 0, cache: Cache.empty())
  for path in texts.keys
    session = update(session, path, texts[path])
  end
  return session
end

## `session` with `text` as the content of the file `path`, whether or not the disk has it. Two spellings of one file
## are one buffer.
export def update(session: Session, path: String, text: String) -> Session
  settings = session.settings
  buffer = Overlay.buffer(settings.workspace, settings.env.windows, path, SourceFile.Read.Text(text))
  return session.with(buffers: Overlay.put(session.buffers, buffer), generation: session.generation + 1)
end

## `session` without the buffer of `path`: the disk answers for the file again.
export def close(session: Session, path: String) -> Session
  settings = session.settings
  kept = Overlay.remove(session.buffers, settings.workspace, settings.env.windows, path)
  return session.with(buffers: kept, generation: session.generation + 1)
end

## `session` with the program of the file `path` linked and checked in its cache, and the files it reads parsed there,
## so the questions that follow reuse them. Only what the files and buffers now say is kept: a root whose modules did
## not change is not checked again, and a module whose text did not change is not parsed again. A file that cannot be
## loaded or linked leaves the cache as it was. The cache belongs to one line of sessions: run one `refresh` at a time
## and keep the session it returns (the cache has no merge of two).
export def refresh(session: Session, path: String) -> Session
  return session.with(cache: Front.refresh(session.cache, path, asking(session)))
end

## The settings a question runs with: those of the session, over a Workspace that answers for its buffers.
export def asking(session: Session) -> Env.Settings
  return session.settings.with(workspace: Overlay.over(session.settings.workspace, session.buffers))
end

## Whether a buffer stands in for the file `path`.
export def buffered?(session: Session, path: String) -> Bool
  settings = session.settings
  return Overlay.holds?(session.buffers, settings.workspace, settings.env.windows, path)
end
