## Runs the system `git` for the package commands (docs/future/45-packages.md, 45.8): the user's git config, SSH keys
## and credential helpers apply, and the front end keeps no tokens of its own. The arguments go straight to git with no
## shell. Standard input is closed at once, so git never waits for text from this process (git may still ask on a
## terminal, which the deadline below ends).

import PackageHash from "../packages/package_hash"

# The deadline of each read and of the wait for the exit, in milliseconds: a fetch of a large repository is slow.
GIT_TIMEOUT_MS = 300_000
START_TIMEOUT_MS = 10_000
CLOSE_TIMEOUT_MS = 5_000
# Standard output is read in pieces as it arrives. The VM keeps at most 1 MiB of output that was not read yet and then
# cuts the stream, so a read that waits for a big count would let a large blob overflow it.
CHUNK_BYTES = 65_536

## What a run of git gave. `Exited` has the status, standard output as bytes (a blob is not text) and the standard
## error as text; `Missing` is a git that did not start; `Broken` is a git that started but whose output could not be
## read in time or in full (a deadline, or more output than the VM keeps).
export enum Ran
  Exited(Int, List[Int], String)
  Missing(String)
  Broken(String)
end

## Runs `git` with `arguments` in the folder `dir`, so that it never looks for a repository around the working folder.
export def run(arguments: List[String], dir: String) -> Ran
  spawned = Process.spawn_captured("git", arguments, dir, START_TIMEOUT_MS)
  if !spawned.ok?
    return Ran.Missing(spawned.message)
  end
  child = spawned.unwrap!
  Process.close_stdin(child, CLOSE_TIMEOUT_MS)
  ran = finish(child)
  Process.close(child)
  return ran
end

# Reads standard output to its end, then standard error and the exit status. The pieces are joined once at the end.
def finish(child: Process) -> Ran
  pieces: List[List[Int]] = []
  finished = false
  while !finished
    got = Process.read_bytes(child, CHUNK_BYTES, GIT_TIMEOUT_MS)
    if !got.ok?
      return Ran.Broken(got.message)
    end
    finished = got.unwrap!.size == 0
    pieces = pieces.push(got.unwrap!)
  end
  output = Process.output(child, GIT_TIMEOUT_MS)
  if !output.ok?
    return Ran.Broken(output.message)
  end
  waited = Process.wait(child, GIT_TIMEOUT_MS)
  if !waited.ok?
    return Ran.Broken(waited.message)
  end
  return Ran.Exited(waited.unwrap!, PackageHash.concat_all(pieces), output.unwrap!.stderr)
end
