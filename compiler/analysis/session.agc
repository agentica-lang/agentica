## What a library client keeps between questions (stdlib/analysis.agc): the settings of the machine and the buffers
## that stand in for files. The value is immutable: `update` and `close` give a new one, and a question reads the one
## it is given, so tasks may share a session and ask it at once. Each question builds its Workspace from the buffers
## and runs the stages from the start; the `generation` counts the changes, so a caller can tell a session from an
## older one.

import Env from "../modules/link_env"
import Overlay from "../modules/overlay"
import SourceFile from "../syntax/source_file"

## The settings, the buffers and the number of changes made to them.
export struct Session
  settings: Env.Settings
  buffers: List[Overlay.Buffer]
  generation: Int
end

## A session over the disk of `settings` with the text of each file of `texts` (a path and the text that stands in for
## it).
export def open(settings: Env.Settings, texts: Map[String, String]) -> Session
  session = Session(settings: settings, buffers: [], generation: 0)
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

## The settings a question runs with: those of the session, over a Workspace that answers for its buffers.
export def asking(session: Session) -> Env.Settings
  return session.settings.with(workspace: Overlay.over(session.settings.workspace, session.buffers))
end

## Whether a buffer stands in for the file `path`.
export def buffered?(session: Session, path: String) -> Bool
  settings = session.settings
  return Overlay.holds?(session.buffers, settings.workspace, settings.env.windows, path)
end
