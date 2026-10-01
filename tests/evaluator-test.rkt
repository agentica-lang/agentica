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
                     "  if Map.has(m, \"c\") or m[\"b\"] != 3 or Map.len(m) != 2 or Map.len(n) != 3 or List.len(Map.keys(n)) != 3\n"
                     "    puts(\"wrong\")\n  end")))
                  "b\na\nc\n"))

  (test-case "a missing map key is a located diagnostic"
    (define missing (diagnostic-of (main-with "  m = {\"a\": 1}\n  x = m[\"z\"]")))
    (check-equal? (diagnostic-code missing) 'RUNTIME-KEY-NOT-FOUND)
    (check-equal? (position-of missing) '(3 9)))

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
