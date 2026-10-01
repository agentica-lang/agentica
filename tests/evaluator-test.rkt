#lang racket

(require (except-in rackunit check)
         "../src/checker.rkt"
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

(define (run-io text [input ""] [arguments '()])
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
                           #:args arguments))
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
  (test-case "the section 10 programs run"
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

  (test-case "the String module"
    (check-equal? (output-of
                   (main-with
                    (string-append
                     "  puts(String.from_int(String.length(\"hola\")))\n"
                     "  puts(String.upcase(\"hola\") + String.downcase(\"HOLA\"))\n"
                     "  puts(String.trim(\"  x  \"))\n"
                     "  puts(String.join(String.split(\"a,b,c\", \",\"), \"-\"))\n"
                     "  if String.contains?(\"hola\", \"ol\") and String.starts_with?(\"hola\", \"ho\") and String.ends_with?(\"hola\", \"la\")\n"
                     "    puts(\"found\")\n"
                     "  end\n"
                     "  puts(String.replace(\"aXbX\", \"X\", \"-\"))\n"
                     "  puts(String.slice(\"hola\", 1, 2))\n"
                     "  puts(String.from_float(1.5))\n"
                     "  puts(String.from_int(String.to_int!(\"42\")))\n"
                     "  puts(String.from_float(String.to_float!(\"1.25\")))")))
                  "4\nHOLAhola\nx\na-b-c\nfound\na-b-\nol\n1.5\n42\n1.25\n"))

  (test-case "String.length and String.slice count characters, not bytes"
    (check-equal? (output-of
                   (main-with
                    "  puts(String.from_int(String.length(\"ñ😀\")))\n  puts(String.slice(\"ñ😀x\", 1, 2))"))
                  "2\n😀x\n"))

  (test-case "String.slice and number conversions fail with located diagnostics"
    (define past-end (diagnostic-of (main-with "  x = String.slice(\"abc\", 2, 5)")))
    (check-equal? (diagnostic-code past-end) 'RUNTIME-INDEX-OUT-OF-RANGE)
    (check-equal? (diagnostic-code (diagnostic-of (main-with "  x = String.slice(\"abc\", 0 - 1, 1)")))
                  'RUNTIME-INDEX-OUT-OF-RANGE)
    (check-equal? (diagnostic-code (diagnostic-of (main-with "  x = String.to_int!(\"1.5\")")))
                  'RUNTIME-INVALID-NUMBER)
    (check-equal? (diagnostic-code (diagnostic-of (main-with "  x = String.to_float!(\"abc\")")))
                  'RUNTIME-INVALID-NUMBER))

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

  (test-case "IO.gets reads lines, IO.read drains, and IO.eof? peeks"
    (define-values (output err result)
      (run-io (main-with
               (string-append
                "  if IO.eof?()\n    puts(\"empty\")\n  end\n"
                "  puts(IO.gets())\n"
                "  puts(IO.gets())\n"
                "  puts(IO.read())\n"
                "  if IO.eof?()\n    puts(\"done\")\n  end\n"))
              "one\ntwo\nrest\n"))
    (check-equal? result 'nil)
    (check-equal? output "one\ntwo\nrest\n\ndone\n"))

  (test-case "IO.gets at end of input is a located diagnostic"
    (define-values (output err result) (run-io (main-with "  x = IO.gets()") ""))
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
