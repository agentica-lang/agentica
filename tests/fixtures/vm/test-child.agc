import "std/test/child" as Child
import "std/test/report" as Report

def show(label: String, line: String) -> Void
  puts("#{label}: #{JSON.encode(Child.record_for(line, "k3y"))}")
end

def main() -> Void
  record = "{\"event\":\"pass\",\"token\":\"k3y\"}"
  show("the run token at a line start", Child.marker() + record)
  show("another token", Child.marker() + "{\"event\":\"pass\",\"token\":\"guess\"}")
  show("no token", Child.marker() + "{\"event\":\"pass\"}")
  show("after other text", "text " + Child.marker() + record)
  show("not JSON", Child.marker() + "pass")
  vm = "{\"code\":\"RUNTIME-X\",\"file\":\"a.agc\",\"message\":\"m\",\"range\":{\"end\":{\"column\":3,\"line\":1},\"start\":{\"column\":1,\"line\":1}}}"
  task = vm.slice(0, vm.length - 1) + ",\"task\":true}"
  summary = "{\"unobserved_crashes\":1,\"first\":\"task crashed\"}"
  mine = "{\"code\":\"MINE\",\"level\":\"warn\"}"
  stderr = [mine, task, "plain", vm].join("\n")
  puts(Child.stderr_text(stderr + "\n" + summary).inspect)
  puts(Child.stderr_diagnostic(stderr, Report.Span(file: "a.agc", line: 1, column: 1, end_column: 1)).unwrap!.code)
  puts(Child.stderr_diagnostic(stderr + "\n" + summary, Report.Span(file: "a.agc", line: 1, column: 1, end_column: 1)).unwrap!.code)
  puts(Child.stderr_diagnostic([vm, mine].join("\n"), Report.Span(file: "a.agc", line: 1, column: 1, end_column: 1)).ok?)
end
