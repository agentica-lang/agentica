## The hand-off of an ordinary run: runs a compiled program by starting `agentica-vm` on it, as src/main.rkt does. The
## program is written to a new file of mode 0600 in the temporary directory (a VM started with `--driver-pid` reads
## only a private file, and deletes it after loading it) and `agentica-vm` is started with `--driver-pid`, under a
## shell that names itself, so the VM ends if this process does (and stops the processes it started; see SHELL).
##
## Limits, because a Process gives only pipes (docs/future/35-self-hosting.md, "Step 8a status"; the single binary has
## none of them): the program's standard input and output pass through this process one byte at a time, because
## `Process.read_bytes` and `IO.read_bytes` wait for a whole count and a larger read could hold back a reply an
## interactive program has already made. That is about 3.5 MB in 7 seconds, and the output must be UTF-8 (it is: a
## program prints Strings). The standard error of the program goes straight to this process's, so with `2>&1` the two
## streams can come out of order. The `--flush-timeout 0` message of Racket is missing, and a broken pipe on the
## standard output is reported against cli_main.agc, not against the program.
##
## Two more come from the shell (see SHELL). The shell has no death signal of its own, so when this process is killed
## with SIGKILL the shell, the program's VM and the processes it started stay running (a SIGTERM or an interrupt is
## handled and cleans up). And a shell runs a background job with SIGINT and SIGQUIT ignored, so the program's VM
## ignores them too: `kill -INT` aimed at the VM alone does nothing. The single binary (step 8d) replaces this module
## with a builtin that loads the bytes in the same process, and with it these limits go.

import {IO_TIMEOUT, write_bytes} from "bdd_files"
import RunDir from "bdd_rundir"
import Host from "cli_host"

# The VM runs under a shell that starts it in the background and waits for it. A plain child gets SIGKILL when this
# process ends, and a VM killed that way cannot stop the processes it started. With the shell in between, the shell is
# the one that is killed, the VM's parent dies, and a VM started with --driver-pid gets SIGTERM from the kernel and
# stops its own children, as it does under Racket. The shell is the process that --driver-pid names (the VM checks
# that it is its parent). The standard input moves to descriptor 3 first: a background job of a shell reads /dev/null
# unless it is given another descriptor for it.
SHELL = ["-c", "vm=$1\nshift\nexec 3<&0\n\"$vm\" --driver-pid $$ \"$@\" <&3 3<&- &\nwait $! 2>/dev/null", "sh"]

# The deadline of the start of the VM, and a wait that never ends in practice (a year): a timeout of a read of the
# program's output would stop the program.
START_TIMEOUT = 30000
FOREVER = 31536000000

## Runs the program of `launch` on the VM of `host` and gives its exit status. A VM that is missing, a temporary file
## that cannot be written or a VM that cannot start print one line on stderr and give 2.
export def hand_off(host: Host.Host, launch: Host.Launch) -> Int
  vm = host.vm
  if !runnable?(vm)
    IO.warn(missing_text(vm))
    return 2
  end
  temporary = RunDir.temporary_directory()
  if !temporary.ok?
    IO.warn(unwritable(RunDir.temporary_candidates()[0]))
    return 2
  end
  name = RunDir.random_hex()
  if !name.ok?
    IO.warn(unwritable(temporary.unwrap!))
    return 2
  end
  path = "#{temporary.unwrap!}/agentica-#{name.unwrap!}.agcb"
  written = write_bytes(path, launch.bytes)
  if !written.ok?
    Path.remove(path, IO_TIMEOUT)
    IO.warn(unwritable(temporary.unwrap!))
    return 2
  end
  status = run(vm, path, launch)
  Path.remove(path, IO_TIMEOUT)
  # `run` answers -1 (an exit status is never negative) when the VM could not be started or waited for.
  if status < 0
    IO.warn("agentica: cannot run the VM at #{vm}")
    return 2
  end
  return status
end

## True when `vm` is a file that someone can execute (Racket checks the permission of this user; here any execute bit).
export def runnable?(vm: String) -> Bool
  found = File.stat(vm, IO_TIMEOUT)
  return found.ok? and found.unwrap!.kind == "file" and found.unwrap!.mode.bit_and(73) != 0
end

## The line printed when there is no VM to run anything with.
export def missing_text(vm: String) -> String
  return "agentica: cannot find the VM at #{vm}; run make vm or set AGENTICA_VM"
end

# The line printed when the temporary directory cannot take the program's file. Racket names the directory with a
# slash at its end, so this does too.
def unwritable(directory: String) -> String
  if directory.ends_with?("/")
    return "agentica: cannot write a temporary file in #{directory}"
  end
  return "agentica: cannot write a temporary file in #{directory}/"
end

# Starts the VM on the file and passes the streams through until it ends. It gives the exit status, or -1 when the VM
# cannot be started or waited for.
def run(vm: String, path: String, launch: Host.Launch) -> Int
  words = launch.flags.concat(["--", path]).concat(launch.arguments)
  spawned = Process.spawn("/bin/sh", SHELL.concat([vm]).concat(words), START_TIMEOUT)
  if !spawned.ok?
    return -1
  end
  child = spawned.unwrap!
  Task.spawn(&forward_input, child)
  forward_output(child)
  waited = Process.wait(child, FOREVER)
  Process.close(child)
  if !waited.ok?
    return -1
  end
  return waited.unwrap!
end

# This process's standard input to the program's, until the end of either.
def forward_input(child: Process) -> Void
  while true
    got = IO.read_bytes(1)
    if !got.ok? or got.unwrap!.size == 0
      Process.close_stdin(child, IO_TIMEOUT)
      return
    end
    if !Process.send_bytes(child, got.unwrap!, FOREVER).ok?
      return
    end
  end
end

# The program's standard output to this process's, a character at a time: a byte below 128 is a character, and a lead
# byte starts a sequence that is printed when its last byte comes. A byte that is not valid UTF-8 prints as U+FFFD.
def forward_output(child: Process) -> Void
  pending: List[Int] = []
  needed = 0
  while true
    got = Process.read_bytes(child, 1, FOREVER)
    if !got.ok? or got.unwrap!.size == 0
      if pending.size > 0
        print(String.from_code(65533))
      end
      return
    end
    byte = got.unwrap![0]
    if byte >= 128 and byte < 192 and pending.size > 0
      pending = pending.push(byte)
      if pending.size == needed
        print(String.from_bytes(pending).unwrap_or(String.from_code(65533)))
        pending = []
      end
    else
      if pending.size > 0
        print(String.from_code(65533))
        pending = []
      end
      if byte < 128
        print(String.from_code(byte))
      elsif byte >= 194 and byte < 245
        pending = [byte]
        needed = sequence_length(byte)
      else
        print(String.from_code(65533))
      end
    end
  end
end

# The length of the sequence that a lead byte (194 to 244) starts.
def sequence_length(lead: Int) -> Int
  if lead < 224
    return 2
  elsif lead < 240
    return 3
  end
  return 4
end
