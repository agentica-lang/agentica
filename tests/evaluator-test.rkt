#lang racket

(require (except-in rackunit check)
         "../src/checker.rkt"
         "../src/builtins.rkt"
         "../src/diagnostic.rkt"
         "../src/evaluator.rkt"
         "../src/lexer.rkt"
         "../src/parser.rkt"
         "../src/source.rkt")

(define (run text)
  (define lexed (lex (source "test.agc" text)))
  (define parsed (if (diagnostic? lexed) lexed (parse lexed)))
  (define checked (if (diagnostic? parsed) parsed (check parsed)))
  (when (diagnostic? checked)
    (error 'evaluator-test "program rejected before running: ~a" (format-diagnostic checked)))
  (define result #f)
  (define output (with-output-to-string (lambda () (set! result (evaluate checked)))))
  (values output result))

(define (output-of text)
  (define-values (output result) (run text))
  (when (diagnostic? result)
    (error 'evaluator-test "unexpected diagnostic: ~a" (format-diagnostic result)))
  output)

(define (run-io text [input ""] [arguments '()] #:max-steps [max-steps #f])
  (define lexed (lex (source "test.agc" text)))
  (define parsed (if (diagnostic? lexed) lexed (parse lexed)))
  (define checked (if (diagnostic? parsed) parsed (check parsed)))
  (when (diagnostic? checked)
    (error 'evaluator-test "program rejected before running: ~a" (format-diagnostic checked)))
  (define out (open-output-string))
  (define err (open-output-string))
  (define result (evaluate checked
                           #:in (open-input-string input)
                           #:out out
                           #:err err
                           #:args arguments
                           #:max-steps max-steps))
  (values (get-output-string out) (get-output-string err) result))

(define (diagnostic-of text)
  (define-values (output result) (run text))
  (unless (diagnostic? result)
    (error 'evaluator-test "expected a runtime diagnostic, got ~s" result))
  result)

(define (main-with body)
  (format "def main() -> Nil\n~a\nend\n" body))

(define (position-of problem)
  (define start (source-span-start (diagnostic-span problem)))
  (list (source-position-line start) (source-position-column start)))

(module+ test
  (test-case "the section 8 programs run"
    (check-equal? (output-of "def main() -> Nil\n  puts(\"hello\")\nend\n") "hello\n")
    (check-equal? (output-of (string-append
                              "def classify(age: Int) -> String\n"
                              "  if age >= 18\n    return \"adult\"\n"
                              "  elsif age >= 13\n    return \"teen\"\n"
                              "  else\n    return \"child\"\n  end\nend\n\n"
                              "def main() -> Nil\n"
                              "  puts(classify(25))\n  puts(classify(15))\n  puts(classify(3))\nend\n"))
                  "adult\nteen\nchild\n")
    (check-equal? (output-of (string-append
                              "struct Task\n  title: String\n  done: Bool\nend\n\n"
                              "def main() -> Nil\n"
                              "  tasks: List[Task] = [\n"
                              "    Task(title: \"a\", done: false),\n"
                              "    Task(done: true, title: \"b\"),\n"
                              "    Task(title: \"c\", done: false)\n  ]\n"
                              "  for task in tasks\n    if not task.done\n      puts(task.title)\n    end\n  end\nend\n"))
                  "a\nc\n"))

  (test-case "control flow, scopes, and recursion"
    (check-equal? (output-of (string-append
                              "def fact(n: Int) -> Int\n"
                              "  if n <= 1\n    return 1\n  end\n  return n * fact(n - 1)\nend\n\n"
                              "def find(xs: List[Int], target: Int) -> Int\n"
                              "  for x in xs\n    if x == target\n      return x\n    end\n  end\n  return 0\nend\n\n"
                              "def main() -> Nil\n"
                              "  i = 0\n  total = 0\n"
                              "  while i < 4\n    total = total + i\n    i = i + 1\n  end\n"
                              "  empty: List[Int] = []\n  for e in empty\n    puts(\"never\")\n  end\n"
                              "  if total == 6\n    puts(\"six\")\n  end\n"
                              "  puts(\"ok\")\nend\n"
                              "def unused() -> Nil\n  puts(\"\")\nend\n"))
                  "six\nok\n")
    (check-equal? (output-of (string-append
                              "def fact(n: Int) -> Int\n"
                              "  if n <= 1\n    return 1\n  end\n  return n * fact(n - 1)\nend\n\n"
                              "def main() -> Nil\n  if fact(5) == 120 and later() == 1\n    puts(\"yes\")\n  end\nend\n"
                              "def later() -> Int\n  return 1\nend\n"))
                  "yes\n"))

  (test-case "operators"
    (check-equal? (output-of
                   (string-append
                    "def noisy() -> Bool\n  puts(\"ran\")\n  return true\nend\n\n"
                    "def main() -> Nil\n"
                    "  if false and noisy()\n    puts(\"no\")\n  end\n"
                    "  if true or noisy()\n    puts(\"skip\")\n  end\n"
                    "  a = 0 - 7\n"
                    "  if a / 2 == 0 - 3 and a % 2 == 0 - 1\n    puts(\"trunc\")\n  end\n"
                    "  puts(\"a\" + \"b\")\nend\n"))
                  "skip\ntrunc\nab\n"))

  (test-case "maps are immutable and keep insertion order"
    (check-equal? (output-of
                   (main-with
                    (string-append
                     "  m: Map[String, Int] = {\"b\": 1, \"a\": 2, \"b\": 3}\n"
                     "  n = Map.put(m, \"c\", 4)\n"
                     "  for k in Map.keys(n)\n    puts(k)\n  end\n"
                     "  if Map.has_key?(m, \"c\") or m[\"b\"] != 3 or Map.size(m) != 2 or Map.size(n) != 3 or List.size(Map.keys(n)) != 3\n"
                     "    puts(\"wrong\")\n  end")))
                  "b\na\nc\n"))

  (test-case "a missing map key is a located diagnostic"
    (define missing (diagnostic-of (main-with "  m = {\"a\": 1}\n  x = m[\"z\"]")))
    (check-equal? (diagnostic-code missing) 'RUNTIME-KEY-NOT-FOUND)
    (check-equal? (position-of missing) '(3 9)))

  (test-case "String.slice and number conversions fail with located diagnostics"
    (define past-end (diagnostic-of (main-with "  x = String.slice(\"abc\", 2, 5)")))
    (check-equal? (diagnostic-code past-end) 'RUNTIME-INDEX-OUT-OF-RANGE)
    (check-equal? (diagnostic-code (diagnostic-of (main-with "  x = String.slice(\"abc\", 0 - 1, 1)")))
                  'RUNTIME-INDEX-OUT-OF-RANGE)
    (check-equal? (diagnostic-code (diagnostic-of (main-with "  x = String.to_int!(\"1.5\")")))
                  'RUNTIME-INVALID-NUMBER)
    (check-equal? (diagnostic-code (diagnostic-of (main-with "  x = String.to_int!(\"#x10\")")))
                  'RUNTIME-INVALID-NUMBER)
    (check-equal? (diagnostic-code (diagnostic-of (main-with "  x = String.to_int!(\"9223372036854775808\")")))
                  'RUNTIME-INTEGER-OVERFLOW)
    (check-equal? (diagnostic-code (diagnostic-of (main-with "  x = String.to_float!(\"abc\")")))
                  'RUNTIME-INVALID-NUMBER)
    (check-equal? (diagnostic-code (diagnostic-of (main-with "  x = String.to_float!(\"1+2i\")")))
                  'RUNTIME-INVALID-NUMBER)
    (check-equal? (diagnostic-code (diagnostic-of (main-with "  x = String.to_float!(\"1/2\")")))
                  'RUNTIME-INVALID-NUMBER))

  (test-case "user functions may use ? and ! suffixes"
    (check-equal? (output-of
                   (string-append
                    "def ready?() -> Bool\n  return true\nend\n\n"
                    "def value!() -> String\n  return \"ok\"\nend\n\n"
                    "def main() -> Nil\n"
                    "  if ready?()\n    puts(value!())\n  end\n"
                    "end\n"))
                  "ok\n"))

  (test-case "IO writes to the injected ports and inspect returns its value"
    (define-values (output err result)
      (run-io (main-with
               (string-append
                "  IO.puts(\"a\")\n"
                "  IO.print(\"b\")\n"
                "  IO.warn(\"w\")\n"
                "  x = IO.inspect([1, 2])\n"
                "  puts(String.from_int(List.size(x)))"))))
    (check-equal? result 'nil)
    (check-equal? output "a\nb[1, 2]\n2\n")
    (check-equal? err "w\n"))

  (test-case "IO.inspect prints structs, lists, and maps in a stable form"
    (define-values (output err result)
      (run-io (string-append
               "struct Task\n  title: String\n  done: Bool\nend\n\n"
               "def main() -> Nil\n"
               "  t = Task(done: true, title: \"a\")\n"
               "  IO.inspect(t)\n"
               "  IO.inspect({\"k\": 1})\n"
               "  IO.inspect(\"hi\")\n"
               "  IO.inspect(nil)\n"
               "end\n")))
    (check-equal? result 'nil)
    (check-equal? output "Task(title: \"a\", done: true)\n{\"k\": 1}\n\"hi\"\nnil\n"))

  (test-case "IO.gets! reads lines, IO.read drains, and IO.eof? peeks"
    (define-values (output err result)
      (run-io (main-with
               (string-append
                "  if IO.eof?()\n    puts(\"empty\")\n  end\n"
                "  puts(IO.gets!())\n"
                "  puts(IO.gets!())\n"
                "  puts(IO.read())\n"
                "  if IO.eof?()\n    puts(\"done\")\n  end\n"))
              "one\r\ntwo\rrest\n"))
    (check-equal? result 'nil)
    (check-equal? output "one\ntwo\nrest\n\ndone\n"))

  (test-case "IO.gets! at end of input is a located diagnostic"
    (define-values (output err result) (run-io (main-with "  x = IO.gets!()") ""))
    (check-true (diagnostic? result))
    (check-equal? (diagnostic-code result) 'RUNTIME-END-OF-INPUT)
    (check-equal? (position-of result) '(2 7)))

  (test-case "System.args and System.exit"
    (define-values (args-output err args-result)
      (run-io (main-with "  for a in System.args()\n    puts(a)\n  end") "" '("x" "y")))
    (check-equal? args-result 'nil)
    (check-equal? args-output "x\ny\n")
    (define-values (exit-output exit-err result) (run-io (main-with "  System.exit(3)")))
    (check-true (exit-code? result))
    (check-equal? (exit-code-code result) 3))

  (test-case "every catalog entry is typed and dispatched through a real program"
    ;; Independent examples and expected output, not signatures copied from the catalog.
    (define samples
      '(("puts" "puts(\"x\")" "x\nnil\n")
        ("IO.puts" "IO.puts(\"x\")" "x\nnil\n")
        ("IO.print" "IO.print(\"x\")" "xnil\n")
        ("IO.warn" "IO.warn(\"x\")" "nil\n")
        ("IO.inspect" "IO.inspect(7)" "7\n7\n")
        ("IO.gets" "IO.gets()" "ok(\"line\")\n")
        ("IO.gets!" "IO.gets!()" "\"line\"\n")
        ("IO.read" "IO.read()" "\"line\\n\"\n")
        ("IO.eof?" "IO.eof?()" "false\n")
        ("System.args" "System.args()" "[\"arg\"]\n")
        ("System.exit" "System.exit(0)" "")
        ("Map.has_key?" "Map.has_key?({\"k\": 1}, \"k\")" "true\n")
        ("Map.keys" "Map.keys({\"k\": 1})" "[\"k\"]\n")
        ("Map.size" "Map.size({\"k\": 1})" "1\n")
        ("Map.put" "Map.put({\"k\": 1}, \"k\", 2)" "{\"k\": 2}\n")
        ("List.size" "List.size([1, 2])" "2\n")
        ("String.length" "String.length(\"ñ😀\")" "2\n")
        ("String.upcase" "String.upcase(\"a\")" "\"A\"\n")
        ("String.downcase" "String.downcase(\"A\")" "\"a\"\n")
        ("String.trim" "String.trim(\" a \")" "\"a\"\n")
        ("String.split" "String.split(\"ñ😀\", \"\")" "[\"ñ\", \"😀\"]\n")
        ("String.join" "String.join([\"a\", \"b\"], \",\")" "\"a,b\"\n")
        ("String.contains?" "String.contains?(\"abc\", \"b\")" "true\n")
        ("String.starts_with?" "String.starts_with?(\"abc\", \"a\")" "true\n")
        ("String.ends_with?" "String.ends_with?(\"abc\", \"c\")" "true\n")
        ("String.replace" "String.replace(\"aXb\", \"X\", \"-\")" "\"a-b\"\n")
        ("String.slice" "String.slice(\"ñ😀x\", 1, 2)" "\"😀x\"\n")
        ("String.from_int" "String.from_int(7)" "\"7\"\n")
        ("String.from_float" "String.from_float(1.5)" "\"1.5\"\n")
        ("String.to_int" "String.to_int(\"7\")" "ok(7)\n")
        ("String.to_float" "String.to_float(\"1.5\")" "ok(1.5)\n")
        ("String.to_int!" "String.to_int!(\"7\")" "7\n")
        ("String.to_float!" "String.to_float!(\"1.5\")" "1.5\n")
        ("ok" "ok(7)" "ok(7)\n")
        ("error" "r" "error(\"bad\")\n")
        ("Result.ok?" "Result.ok?(ok(7))" "true\n")
        ("Result.unwrap!" "Result.unwrap!(ok(7))" "7\n")
        ("Result.unwrap_or" "Result.unwrap_or(r, 7)" "7\n")
        ("Result.message" "Result.message(r)" "\"bad\"\n")))
    (for ([name (in-list (sort (hash-keys builtins) string<?))])
      (define sample (assoc name samples))
      (unless sample (error 'catalog-test "missing behavioral example for ~a" name))
      (define-values (out err result)
        (run-io (main-with (format "  r: Result[Int] = error(\"bad\")\n  IO.inspect(~a)" (cadr sample)))
                "line\n" '("arg")))
      (check-equal? out (caddr sample) name)
      (check-equal? err (if (equal? name "IO.warn") "x\n" "") name)
      (if (equal? name "System.exit")
          (check-equal? (exit-code-code result) 0)
          (check-equal? result 'nil name))))

  (test-case "Result values, false/nil successes, and recoverable conversions"
    (check-equal?
     (output-of
      (main-with
       (string-append
        "  IO.inspect(ok(false))\n  IO.inspect(ok(nil))\n"
        "  r: Result[Int] = error(\"bad\")\n"
        "  IO.inspect(r)\n  IO.inspect(Result.ok?(r))\n"
        "  IO.inspect(Result.unwrap!(ok(false)))\n"
        "  IO.inspect(Result.unwrap!(ok(nil)))\n"
        "  IO.inspect(Result.message(ok(1)))\n  puts(Result.message(r))\n"
        "  IO.inspect(Result.unwrap_or(r, 7))\n"
        "  IO.inspect(String.to_int(\"-9223372036854775808\"))\n"
        "  IO.inspect(String.to_int(\"9223372036854775807\"))\n"
        "  IO.inspect(Result.ok?(String.to_int(\"9223372036854775808\")))\n"
        "  IO.inspect(Result.ok?(String.to_int(\"-9223372036854775809\")))\n"
        "  IO.inspect(Result.ok?(String.to_int(\"1.5\")))\n"
        "  IO.inspect(Result.ok?(String.to_int(\"#x10\")))\n"
        "  IO.inspect(String.to_float(\"+1.25\"))\n"
        "  IO.inspect(Result.ok?(String.to_float(\"1/2\")))\n"
        "  IO.inspect(Result.ok?(String.to_float(\"1+2i\")))\n"
        "  puts(\"continued\")")))
     (string-append "ok(false)\nok(nil)\nerror(\"bad\")\nfalse\nfalse\nnil\n\"\"\nbad\n7\n"
                    "ok(-9223372036854775808)\nok(9223372036854775807)\n"
                    "false\nfalse\nfalse\nfalse\nok(1.25)\nfalse\nfalse\ncontinued\n"))
    (define problem (diagnostic-of (main-with "  r: Result[Int] = error(\"bad\")\n  x = Result.unwrap!(r)")))
    (check-equal? (diagnostic-code problem) 'RUNTIME-UNWRAP-ERROR)
    (check-equal? (position-of problem) '(3 7)))

  (test-case "recoverable IO.gets distinguishes blank lines and EOF"
    (define-values (out err result)
      (run-io (main-with "  for n in [1, 2, 3, 4, 5, 6]\n    r = IO.gets()\n    IO.inspect(Result.ok?(r))\n    IO.inspect(Result.unwrap_or(r, \"EOF\"))\n  end")
              "\none\rtwo\r\nthree\nfour"))
    (check-equal? result 'nil)
    (check-equal? err "")
    (check-equal? out "true\n\"\"\ntrue\n\"one\"\ntrue\n\"two\"\ntrue\n\"three\"\ntrue\n\"four\"\nfalse\n\"EOF\"\n"))

  (test-case "try evaluates once and propagates from the current function only"
    (check-equal?
     (output-of
      (string-append
       "def operand() -> Result[Int]\n  puts(\"operand\")\n  return error(\"bad\")\nend\n"
       "def later() -> Int\n  puts(\"later\")\n  return 9\nend\n"
       "def pair(a: Int, b: Int) -> Int\n  return a + b\nend\n"
       "def propagate() -> Result[String]\n"
       "  for n in [1]\n    while true\n"
       "      value = pair(try operand(), later())\n"
       "      return ok(String.from_int(value))\n    end\n  end\n"
       "  return ok(\"empty\")\nend\n"
       "def success() -> Result[String]\n  n = try ok(7)\n  return ok(String.from_int(n))\nend\n"
       "def main() -> Nil\n  local = \"caller\"\n"
       "  r = propagate()\n  puts(Result.message(r))\n  puts(local)\n"
       "  puts(Result.unwrap!(success()))\nend\n"))
     "operand\nbad\ncaller\n7\n"))

  (test-case "unwrap_or evaluates its default eagerly after its Result"
    (check-equal?
     (output-of
      (string-append
       "def first() -> Result[Int]\n  puts(\"first\")\n  return ok(1)\nend\n"
       "def second() -> Int\n  puts(\"second\")\n  return 2\nend\n"
       (main-with "  IO.inspect(Result.unwrap_or(first(), second()))")))
     "first\nsecond\n1\n"))

  (test-case "step budgets bound empty infinite loops and reset each run"
    (define looping (main-with "  while true\n  end"))
    (for ([iteration (in-range 2)])
      (define-values (out err result) (run-io looping #:max-steps 10))
      (check-equal? out "")
      (check-equal? err "")
      (check-equal? (diagnostic-code result) 'RUNTIME-STEP-LIMIT)
      (check-equal? (position-of result) '(2 9)))
    (define-values (out err result) (run-io (main-with "  puts(\"done\")") #:max-steps 3))
    (check-equal? result 'nil)
    (check-equal? out "done\n"))

  (test-case "runtime errors are located diagnostics"
    (define overflow (diagnostic-of (main-with "  x = 9223372036854775807 + 1")))
    (check-equal? (diagnostic-code overflow) 'RUNTIME-INTEGER-OVERFLOW)
    (define negative (diagnostic-of (main-with "  x = 0 - 9223372036854775807 - 1\n  y = -x")))
    (check-equal? (diagnostic-code negative) 'RUNTIME-INTEGER-OVERFLOW)
    (define divide (diagnostic-of (main-with "  x = 1 / 0")))
    (check-equal? (diagnostic-code divide) 'RUNTIME-DIVISION-BY-ZERO)
    (check-equal? (position-of divide) '(2 9))
    (check-equal? (diagnostic-code (diagnostic-of (main-with "  x = 1.0 / 0.0")))
                  'RUNTIME-DIVISION-BY-ZERO)
    (check-equal? (diagnostic-code (diagnostic-of (main-with "  x = 1 % 0")))
                  'RUNTIME-DIVISION-BY-ZERO)
    (define past-end (diagnostic-of (main-with "  xs = [1, 2]\n  y = xs[2]")))
    (check-equal? (diagnostic-code past-end) 'RUNTIME-INDEX-OUT-OF-RANGE)
    (check-equal? (position-of past-end) '(3 10))
    (check-equal? (diagnostic-code (diagnostic-of (main-with "  xs = [1, 2]\n  y = xs[0 - 1]")))
                  'RUNTIME-INDEX-OUT-OF-RANGE)
    (check-equal? (diagnostic-code
                   (diagnostic-of (string-append
                                   "def loop(n: Int) -> Int\n  return loop(n + 1)\nend\n"
                                   "def main() -> Nil\n  x = loop(0)\nend\n")))
                  'RUNTIME-STACK-OVERFLOW)))
