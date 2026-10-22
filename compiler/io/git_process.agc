## Runs the system `git` for the package commands (docs/future/45-packages.md, 45.8): the user's git config, SSH keys
## and credential helpers apply, and the front end keeps no tokens of its own. The arguments go straight to git with no
## shell. Standard input is closed at once, so git never waits for text from this process.

# The deadline of each read and of the wait for the exit, in milliseconds: a fetch of a large repository is slow.
GIT_TIMEOUT_MS = 300_000
START_TIMEOUT_MS = 10_000
CLOSE_TIMEOUT_MS = 5_000
CHUNK_BYTES = 1_048_576

## What a run of git gave. `Exited` has the status, standard output as bytes (a blob is not text) and the standard
## error as text; `Unavailable` is a git that did not start or whose output could not be read.
export enum Ran
  Exited(Int, List[Int], String)
  Unavailable(String)
end

## Runs `git` with `arguments`.
export def run(arguments: List[String]) -> Ran
  spawned = Process.spawn_captured("git", arguments, ".", START_TIMEOUT_MS)
  if !spawned.ok?
    return Ran.Unavailable(spawned.message)
  end
  child = spawned.unwrap!
  Process.close_stdin(child, CLOSE_TIMEOUT_MS)
  ran = finish(child)
  Process.close(child)
  return ran
end

# Reads standard output to its end (the VM keeps the child from blocking on a full pipe), then standard error and the
# exit status.
def finish(child: Process) -> Ran
  data: List[Int] = []
  finished = false
  while !finished
    got = Process.read_bytes(child, CHUNK_BYTES, GIT_TIMEOUT_MS)
    if !got.ok?
      return Ran.Unavailable(got.message)
    end
    finished = got.unwrap!.size == 0
    data = data.concat(got.unwrap!)
  end
  output = Process.output(child, GIT_TIMEOUT_MS)
  if !output.ok?
    return Ran.Unavailable(output.message)
  end
  waited = Process.wait(child, GIT_TIMEOUT_MS)
  if !waited.ok?
    return Ran.Unavailable(waited.message)
  end
  return Ran.Exited(waited.unwrap!, data, output.unwrap!.stderr)
end
