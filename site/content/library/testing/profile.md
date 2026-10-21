---
title: Profile
weight: 3
description: Measure sections of a program in steps and time, count the steps of a task, and write input for flame graphs.
---

`Profile` is a builtin module; it needs no import. `Profile.measure` names a section of a program for the profile, and `Profile.steps` counts the steps of the running task. Both work the same whether the profile is on or off, so they can stay in the code.

Steps are the unit of work of the VM: the entries that `--max-steps` counts. They repeat exactly from run to run, so they are the numbers to compare. Wall time changes with the machine and its load.

## Profile.measure

```text
Profile.measure(label: String, block: Fn[T]) -> T
```

Runs the block once and gives back its value. The block takes no parameters; a function value of no parameters works too (`Profile.measure("load", &load)`).

```agentica
def total(n: Int) -> Int
  sum = 0
  for k in 0...n
    sum += k
  end
  return sum
end

def main() -> Void
  t = Profile.measure("total") do total(1000) end
  puts(t)
end
```

```output
499500
```

A block that uses `try` gives a `Result`. Give the call a `Result` type, so the block knows it gives one:

```agentica
def parse(text: String) -> Result[Int]
  n = try text.to_int
  return ok(n)
end

def main() -> Void
  r: Result[Int] = Profile.measure("parse") do
    a = try parse("12")
    b = try parse("30")
    ok(a + b)
  end
  puts(r.unwrap_or(0))
end
```

```output
42
```

Without the profile, a measure is one block call: one step and the block's own work. With the profile on (below), each label gets a `section` row:

- `calls`: how many times a measure of the label ran.
- `steps`, `us`, `gc_ms`: the steps of the task, the wall time in microseconds and the garbage collector's time in milliseconds, from the start of the block to its end.

Sections are inclusive: a section holds the sections nested in it, so `outer` below counts the steps of both `inner` calls too. A label that runs inside itself in the same task (recursion) counts every call, but its steps and time only once, for the outermost call. Steps are those of the task that runs the measure, so a measure in a task counts only that task's steps; time is wall time, and it goes on while the task waits. A measure whose block ends in a runtime error or a cancel counts as a call with no steps.

```agentica
def work(n: Int) -> Int
  sum = 0
  i = 0
  while i < n
    sum += i
    i += 1
  end
  return sum
end

def main() -> Void
  both = Profile.measure("outer") do
    a = Profile.measure("inner") do work(100) end
    b = Profile.measure("inner") do work(200) end
    a + b
  end
  puts(both)
end
```

```output
24850
```

## Profile.steps

```text
Profile.steps() -> Int
```

The steps the running task has run so far. The count is the same on every run of the same work, with or without the profile, so a test can hold code to a step budget. Each task has its own count.

```agentica
def work(n: Int) -> Int
  sum = 0
  for k in 0...n
    sum += k
  end
  return sum
end

def cost(n: Int) -> Int
  before = Profile.steps()
  work(n)
  return Profile.steps() - before
end

def main() -> Void
  puts(cost(100) == cost(100))
  puts(cost(200) > cost(100))
end
```

```output
true
true
```

## The profile report

Set `AGENTICA_VM_TRACE=profile` to get a report on stderr when the run ends (`AGENTICA_VM_TRACE_FILE=PATH` writes it to a file instead). After the rows of functions, files and builtins come up to 30 `section` rows, the most steps first:

```text
AGENTICA_VM_TRACE=profile agentica sections.agc
...
agc-trace +0.004012 profile section calls=1 steps=2241 us=33 gc_ms=0 name=outer
agc-trace +0.004015 profile section calls=2 steps=2228 us=31 gc_ms=0 name=inner
```

`agentica FILE.agc` prints two reports, the front end's and then the program's; the sections are in the program's.

A run keeps up to 4096 labels. Every label after that counts in one `[overflow]` section (the frame `measure[overflow]` in folded stacks), so a label built from data, such as `"item #{i}"`, cannot grow the profile without bound.

## Flame graphs

Add `AGENTICA_PROFILE_FORMAT=folded` to the profile to get folded stacks instead of the report: one line per distinct stack, the frames from the outermost in, separated by `;`, then a space and the weight in steps. flamegraph.pl, inferno and speedscope read this format.

```text
AGENTICA_VM_TRACE=profile AGENTICA_PROFILE_FORMAT=folded AGENTICA_VM_TRACE_FILE=app.folded agentica app.agc
flamegraph.pl app.folded > app.svg
inferno-flamegraph app.folded > app.svg
```

A file looks like this:

```text
main@app.agc:25;measure:outer;block@app.agc:27:32;measure:inner;block@app.agc:28:34;work@app.agc:1 1000
main@app.agc:25;Int.times;block@app.agc:40:11 1000
```

- A function is `name@FILE:LINE`, a block `block@FILE:LINE:COL`, a native loop or callback (`Int.times`, `List.map`) its builtin's name, and a `Profile.measure` `measure:LABEL`.
- The VM takes a sample of the running task's stack every 1000 steps, each with a weight of 1000. `AGENTICA_PROFILE_SAMPLE=N` sets N (1 to 1000000000); `AGENTICA_PROFILE_SAMPLE=1` counts every step, and the weights then add up to the report's `steps`.
- Sampling counts steps, not time, so the file is the same on every run of the same program, on every system. There is no time weight, since it would differ from run to run.
- Stacks deeper than 512 frames keep the outer and inner halves around a `...` frame. A `;`, a `%` or a control character in a name is written as `%XX` (`%3B`, `%25`), so two different stacks never share a line.
- The file keeps up to 1,048,576 distinct stacks (and 256 MiB of frames). Past that, the weight of each new stack goes to one `[truncated]` line at the end, and an `agc-trace folded profile full` line follows it.
- Use `AGENTICA_VM_TRACE_FILE`: on stderr, the lines mix with what the program writes there. With `agentica FILE.agc`, the file holds the program's stacks only; `agentica check FILE.agc` writes the front end's.

## Performance notes

- With the profile off, `Profile.steps` is one builtin call; leave `Profile.measure` and `Profile.steps` in the code.
- The profile counts every step, so a profiled run is about a third slower. Folded output at the default sample adds a few percent more; a sample every 100 steps adds about a fifth.
- Rank by steps; use `us` to compare builtins and sections in one run, and time the program without the profile.
- The profile runs on one scheduler: a profiled run uses one unless `--schedulers` or `AGENTICA_SCHEDULERS` asks for more, which it refuses.
