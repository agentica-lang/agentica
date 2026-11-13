## The line coverage of `agentica test --coverage`.
##
## Each child that runs a test file or a scenario writes its own LCOV part (`agentica run --coverage FILE`, which the
## VM writes in vm/cover.c). The runner adds the parts up here and writes one report. The report does not depend on the
## order in which the children ended: the parts are read in name order, the files are written in name order, and the
## lines in line order. A function keeps the order in which the parts first list it, sorted by its line.

## A function of a source: the line of its `def` and how many times it was called.
struct Function
  name: String
  line: Int
  calls: Int
end

## One source file: its functions, and the count of each line that has code.
struct Source
  file: String
  functions: List[Function]
  lines: Map[Int, Int]
end

## One line of the summary: a file, how many of its lines have code, and how many of them ran.
struct Covered
  file: String
  lines: Int
  hit: Int
end

## A part left out because it did not read as LCOV: its file name in the parts folder, and why.
struct Broken
  part: String
  message: String
end

## The coverage of a run: the report written (`path`, "" when none was), its files, the parts left out, and why the
## report could not be written ("" when nothing went wrong).
struct Run
  path: String
  files: List[Covered]
  broken: List[Broken]
  problem: String
end

## The coverage of a run: the parts of the folder `parts` (the `.info` files) added up in name order, without the
## files of `left_out`, and written to coverage/lcov.info.
##
## A part that does not read as LCOV is left out and named in `broken`, and a child that ended without writing one
## (killed at its timeout) adds nothing; neither is a `problem`. With no part (no test ran), nothing is written and an
## old report stays, since an empty report would hide it. A folder that cannot be listed, parts that are all broken
## and a report that cannot be written are a `problem`, which fails the run (`failed?`): an old report stays.
def collect(parts: String, left_out: List[String]) -> Run
  listed = Dir.list(parts, 5000)
  if !listed.ok?
    return Run(path: "", files: [], broken: [], problem: "cannot read the coverage parts: #{listed.message}")
  end

  merged: Map[String, Source] = {}
  broken: List[Broken] = []
  read_any = false
  infos = listed.unwrap!.filter do |name: String| name.end_with?(".info") end
  names = infos.sort
  for name in names
    read = read_part("#{parts}/#{name}")
    if read.ok?
      merged = add(merged, read.unwrap!)
      read_any = true
    else
      broken = broken.push(Broken(part: name, message: read.message))
    end
  end

  covered = Run(path: "", files: summary(merged, left_out), broken: broken, problem: "")
  if !read_any and names.size > 0
    # Every part is broken: an old report would pass for this run's.
    return covered.with(problem: "no coverage part could be read, so #{REPORT} was not written")
  elsif !read_any
    return covered
  end

  written = write_report(text(merged, left_out))
  return covered.with(problem: "cannot write #{REPORT}: #{written.message}") if !written.ok?

  covered.with(path: REPORT)
end

## Whether the coverage fails the run: a report that should have been written was not, so an old one may be stale.
def failed?(run: Run) -> Bool = run.problem != ""

## A path as the report names it: relative to the working directory when it is inside it.
def shown(path: String) -> String
  here = Path.cwd().unwrap_or("")
  return path.slice(here.length + 1, path.length - here.length - 1) if here != "" and path.start_with?("#{here}/")

  path
end

## The sources of an LCOV text, in its order. A line that is not LCOV of the shape the VM writes is an error.
def parse(text: String) -> Result[List[Source]]
  found: List[Source] = []
  current = Source(file: "", functions: [], lines: {})
  open = false
  for line in text.split("\n")
    # TN (a test name) is valid LCOV that the VM does not write; it changes no count.
    if line == "" or line.start_with?("TN:")
      next
    elsif line == "end_of_record" and open
      found = found.push(current)
      open = false
      next
    end

    colon = line.index_of(":").unwrap_or(-1)
    return error("not an LCOV line: #{line}", kind: "argument") if colon < 0

    key = line.slice(0, colon)
    value = line.slice(colon + 1, line.length - colon - 1)
    if key == "SF" and !open
      current = Source(file: value, functions: [], lines: {})
      open = true
    elsif !open
      return error("an LCOV line outside a record: #{line}", kind: "argument")
    elsif key == "FN" or key == "FNDA" or key == "DA"
      current = try with_field(current, key, value)
    elsif key != "FNF" and key != "FNH" and key != "LF" and key != "LH"
      return error("not an LCOV line: #{line}", kind: "argument")
    end
  end

  return error("the last LCOV record has no end_of_record", kind: "argument") if open

  ok(found)
end

## `merged` with the counts of `sources` added, file by file.
def add(merged: Map[String, Source], sources: List[Source]) -> Map[String, Source]
  result = merged
  for source in sources
    known = result.get(source.file, Source(file: source.file, functions: [], lines: {}))
    for line in source.lines.keys
      known = known.with(lines: known.lines.put(line, known.lines.get(line, 0) + source.lines[line]))
    end

    for function in source.functions
      known = add_function(known, function)
    end

    result = result.put(source.file, known)
  end

  result
end

## The LCOV text of `merged`, without the files of `left_out`, in the order of the module doc.
def text(merged: Map[String, Source], left_out: List[String]) -> String
  chunks: List[String] = []
  for file in kept(merged, left_out)
    source = merged[file]
    functions = source.functions.sort_by do |function: Function| function.line end
    lines = source.lines.keys.sort
    record = ["SF:#{file}"]
    record = record.concat(functions.map do |function: Function| "FN:#{function.line},#{function.name}" end)
    record = record.concat(functions.map do |function: Function| "FNDA:#{function.calls},#{function.name}" end)
    record = record.push("FNF:#{functions.size}")
    called = functions.select do |function: Function| function.calls > 0 end
    record = record.push("FNH:#{called.size}")
    record = record.concat(lines.map do |line: Int| "DA:#{line},#{source.lines[line]}" end)
    record = record.push("LF:#{lines.size}")
    hit = lines.select do |line: Int| source.lines[line] > 0 end
    record = record.push("LH:#{hit.size}")
    chunks = chunks.push("#{record.join("\n")}\nend_of_record\n")
  end

  chunks.join("")
end

## The line totals of each file of `merged`, without the files of `left_out`, in name order.
def summary(merged: Map[String, Source], left_out: List[String]) -> List[Covered]
  kept(merged, left_out).map do |file: String|
    lines = merged[file].lines
    hit = lines.keys.select do |line: Int| lines[line] > 0 end
    Covered(file: file, lines: lines.size, hit: hit.size)
  end
end

## The summary after the test report: the report's path (or why there is none), one line for each file and the
## total, then the parts left out.
def report_text(run: Run) -> String
  lines = ["coverage: #{run.path}"]
  if failed?(run)
    lines = ["coverage: [#{PROBLEM_CODE}] #{run.problem}"]
  elsif run.path == ""
    lines = ["coverage: no coverage part was read, so #{REPORT} is unchanged"]
  end

  if failed?(run) or run.path != ""
    for file in run.files
      lines = lines.push("  #{file.file} #{share(file.lines, file.hit)}")
    end

    lines = lines.push("  total #{share(total(run.files, false), total(run.files, true))}")
  end

  for part in run.broken
    lines = lines.push("  left out the coverage part #{part.part}: #{part.message}")
  end

  lines.join("\n")
end

## The `coverage` object of the `--json` report: `{path, lines, hit, files: [{file, lines, hit}], broken: [{part,
## message}], problem: {code, message}}`, with `path` null when no report was written and `problem` null when nothing
## went wrong.
def json(run: Run) -> JSON.Value
  files = run.files.map do |file: Covered|
    JSON.object({"file": JSON.from(file.file), "lines": JSON.from(file.lines), "hit": JSON.from(file.hit)})
  end

  broken = run.broken.map do |part: Broken|
    JSON.object({"part": JSON.from(part.part), "message": JSON.from(part.message)})
  end

  path = JSON.null()
  if run.path != ""
    path = JSON.from(run.path)
  end

  problem = JSON.null()
  if failed?(run)
    problem = JSON.object({"code": JSON.from(PROBLEM_CODE), "message": JSON.from(run.problem)})
  end

  JSON.object({
    "path": path,
    "lines": JSON.from(total(run.files, false)),
    "hit": JSON.from(total(run.files, true)),
    "files": JSON.array(files),
    "broken": JSON.array(broken),
    "problem": problem,
  })
end

private

# Where `agentica test --coverage` writes its report.
REPORT = "coverage/lcov.info"

# The code of a report that cannot be written: the one `agentica --coverage FILE` gives for a file it cannot write.
PROBLEM_CODE = "RUNTIME-INTERNAL"

# The most bytes File.replace takes.
REPLACE_LIMIT = 16777216

# `source` with one FN (line, name), FNDA (calls, name) or DA (line, count). The totals are counted again on writing.
def with_field(source: Source, key: String, value: String) -> Result[Source]
  comma = value.index_of(",").unwrap_or(-1)
  return error("not an LCOV line: #{key}:#{value}", kind: "argument") if comma < 0

  number = try value.slice(0, comma).to_i
  name = value.slice(comma + 1, value.length - comma - 1)
  if key == "DA"
    count = try name.to_i
    return ok(source.with(lines: source.lines.put(number, source.lines.get(number, 0) + count)))
  elsif key == "FN"
    return ok(add_function(source, Function(name: name, line: number, calls: 0)))
  end

  ok(add_function(source, Function(name: name, line: -1, calls: number)))
end

# `source` with the calls of `function` added to the function of that name, or with it as a new one. A line of -1
# (an FNDA) keeps the line that an FN gave.
def add_function(source: Source, function: Function) -> Source
  at = 0
  while at < source.functions.size
    known = source.functions[at]
    if known.name == function.name
      line = known.line
      if line < 0
        line = function.line
      end

      changed = known.with(line: line, calls: known.calls + function.calls)
      return source.with(functions: source.functions.take(at).push(changed).concat(source.functions.drop(at + 1)))
    end

    at += 1
  end

  source.with(functions: source.functions.push(function))
end

def kept(merged: Map[String, Source], left_out: List[String]) -> List[String]
  files = merged.keys.filter do |file: String| !left_out.include?(file) end
  files.sort
end

# "3/4 lines (75.0%)", the share rounded down to a tenth.
def share(lines: Int, hit: Int) -> String
  return "0/0 lines" if lines == 0

  tenths = (hit * 1000) / lines
  "#{hit}/#{lines} lines (#{tenths / 10}.#{tenths % 10}%)"
end

def total(files: List[Covered], hit: Bool) -> Int
  sum = 0
  for file in files
    if hit
      sum += file.hit
    else
      sum += file.lines
    end
  end

  sum
end

# The sources of a part, each named as `shown` names it: a test file's own name is absolute, and an import of it may
# go through `..`.
def read_part(path: String) -> Result[List[Source]]
  handle = try File.open(path, "read", 5000)
  lines: List[String] = []
  line = File.read_line(handle, 5000)
  while line.ok?
    lines = lines.push(line.unwrap!)
    line = File.read_line(handle, 5000)
  end

  _ = File.close(handle, 5000)
  case line
    ok(_) -> nil
    error(e) -> return error(e) if !e.is_a?("io.eof")
  end

  sources = try parse(lines.join("\n"))
  ok(sources.map do |source: Source| source.with(file: shown(Path.resolve(source.file).unwrap_or(source.file))) end)
end

# Puts `report` at REPORT. Over an old report of up to 16 MiB, File.replace swaps it in one step, so a reader never
# sees a part of it. Anything else goes to a new file beside it, which is renamed into place; Path.rename never
# replaces a file, so a bigger report removes the old one first.
def write_report(report: String) -> Result[Void]
  try Dir.mkdir("coverage", 5000)
  bytes = report.bytes
  there = File.stat(REPORT, 5000).ok?
  return File.replace(REPORT, bytes, 5000) if there and bytes.size <= REPLACE_LIMIT

  fresh = "#{REPORT}.#{System.pid()}.new"
  written = write_chunks(fresh, report)
  if written.ok? and there
    written = Path.remove(REPORT, 5000)
  end

  if !written.ok?
    _ = Path.remove(fresh, 5000)
    return written
  end

  case Path.rename(fresh, REPORT, 5000)
    ok(_) -> ok()
    # The old report may be gone already, so the new one stays where it is.
    error(e) -> error(e.with(message: "#{e.message}; the report is at #{fresh}"))
  end
end

# A file gets at most 1 MiB in one write, and a character takes up to 4 bytes.
def write_chunks(path: String, report: String) -> Result[Void]
  # The block form closes the file on every path, so a failed write leaves no open handle (Windows cannot remove an
  # open file).
  File.open(path, "write", 5000) do |out|
    at = 0
    while at < report.length
      size = 250000
      if report.length - at < size
        size = report.length - at
      end

      try File.write(out, report.slice(at, size), 5000)
      at += size
    end

    ok()
  end
end
