import "std/test/child" as Child
import "std/test/report" as Report

def show(label: String, line: String) -> Void
  puts("#{label}: #{JSON.encode(Child.record_of(line))}")
end

def main() -> Void
  show("a record line", "{\"event\":\"pass\",\"index\":3}")
  show("text with a marker", "x" + String.from_code(30) + "agentica-bdd {\"event\":\"pass\"}")
  show("not JSON", "pass")
  show("an empty line", "")
  puts(Child.printed("a\nb\n").inspect)
  puts(Child.printed("a\n\n").inspect)
  puts(Child.printed("a").inspect)
  puts(Child.printed("").inspect)
  vm = "{\"code\":\"RUNTIME-X\",\"file\":\"a.agc\",\"message\":\"m\",\"range\":{\"end\":{\"column\":3,\"line\":1},\"start\":{\"column\":1,\"line\":1}}}"
  task = vm.slice(0, vm.length - 1) + ",\"task\":true}"
  trace = ",\"spawned_at\":{\"column\":1,\"file\":\"a.agc\",\"line\":1},\"stack\":[{\"column\":1,\"file\":\"a.agc\",\"function\":\"f\",\"line\":1}],\"stack_omitted\":2"
  deep = vm.slice(0, vm.length - 1) + trace + "}"
  deep_task = vm.slice(0, vm.length - 1) + trace + ",\"task\":true}"
  summary = "{\"unobserved_crashes\":1,\"first\":\"task crashed\"}"
  mine = "{\"code\":\"MINE\",\"level\":\"warn\"}"
  stderr = [mine, task, "plain", vm].join("\n")
  puts(Child.stderr_text(stderr + "\n" + summary).inspect)
  puts(Child.stderr_diagnostic(stderr, Report.Span(file: "a.agc", line: 1, column: 1, end_column: 1)).unwrap!.code)
  puts(Child.stderr_diagnostic(stderr + "\n" + summary, Report.Span(file: "a.agc", line: 1, column: 1, end_column: 1)).unwrap!.code)
  puts(Child.stderr_diagnostic([vm, mine].join("\n"), Report.Span(file: "a.agc", line: 1, column: 1, end_column: 1)).ok?)
  where = Report.Span(file: "a.agc", line: 1, column: 1, end_column: 1)
  puts(Child.stderr_diagnostic([deep_task, deep].join("\n"), where).unwrap!.code)
  puts(Child.stderr_text([mine, deep_task, deep].join("\n")).inspect)
end
