#lang racket

(require (except-in rackunit check)
         "../src/ast.rkt"
         "../src/checker.rkt"
         "../src/diagnostic.rkt"
         "../src/lexer.rkt"
         "../src/parser.rkt"
         "../src/source.rkt")

(define (check-text text)
  (define parsed (parse (lex (source "test.agc" text))))
  (if (diagnostic? parsed)
      (error 'checker-test "parse failed for ~s: ~a" text (format-diagnostic parsed))
      (check parsed)))

(define (check-ok text)
  (define result (check-text text))
  (when (diagnostic? result)
    (error 'checker-test "expected a checked program for ~s, got: ~a"
           text (format-diagnostic result))))

(define (check-code text)
  (define result (check-text text))
  (if (diagnostic? result)
      (diagnostic-code result)
      (error 'checker-test "expected a diagnostic for ~s, got a program" text)))

(define (main-with body)
  (format "def main() -> Nil\n~a\nend\n" body))

(module+ test
  (test-case "the section 10 programs pass"
    (check-ok "def main() -> Nil\n  puts(\"hello\")\nend\n")
    (check-ok (string-append
               "def classify(age: Int) -> String\n"
               "  if age >= 18\n"
               "    return \"adult\"\n"
               "  elsif age >= 13\n"
               "    return \"teen\"\n"
               "  else\n"
               "    return \"child\"\n"
               "  end\n"
               "end\n"
               "\n"
               "def main() -> Nil\n"
               "  puts(classify(25))\n"
               "end\n"))
    (check-ok (string-append
               "struct Task\n"
               "  title: String\n"
               "  done: Bool\n"
               "end\n"
               "\n"
               "def main() -> Nil\n"
               "  tasks: List[Task] = [\n"
               "    Task(title: \"Probar\", done: false),\n"
               "    Task(title: \"Revisar\", done: true)\n"
               "  ]\n"
               "  for task in tasks\n"
               "    if not task.done\n"
               "      puts(task.title)\n"
               "    end\n"
               "  end\n"
               "end\n")))

  (test-case "forward calls and recursion pass"
    (check-ok (string-append
               "def even(n: Int) -> Bool\n"
               "  if n == 0\n"
               "    return true\n"
               "  else\n"
               "    return odd(n - 1)\n"
               "  end\n"
               "end\n"
               "\n"
               "def odd(n: Int) -> Bool\n"
               "  return even(n)\n"
               "end\n"
               "\n"
               "def main() -> Nil\n"
               "  puts(\"ok\")\n"
               "end\n")))

  (test-case "the rejected section 10 examples fail"
    (check-equal? (check-code (main-with "  age: Int = \"25\"")) 'CHECK-TYPE-MISMATCH)
    (check-equal? (check-code (main-with "  if 1\n    puts(\"hello\")\n  end"))
                  'CHECK-TYPE-MISMATCH)
    (check-equal? (check-code (main-with "  values = []")) 'CHECK-EMPTY-LIST-TYPE))

  (test-case "names and types"
    (check-equal? (check-code (main-with "  x = missing")) 'CHECK-UNKNOWN-NAME)
    (check-equal? (check-code (main-with "  x: Foo = 1")) 'CHECK-UNKNOWN-TYPE)
    (check-equal? (check-code (main-with "  x: List = []")) 'CHECK-UNKNOWN-TYPE)
    (check-equal? (check-code (string-append
                               "def f() -> Nil\nend\n\n"
                               "def f() -> Nil\nend\n\n"
                               "def main() -> Nil\nend\n"))
                  'CHECK-REDEFINED-NAME)
    (check-equal? (check-code (string-append
                               "def puts(value: String) -> Nil\nend\n\n"
                               "def main() -> Nil\nend\n"))
                  'CHECK-REDEFINED-NAME)
    (check-equal? (check-code (string-append
                               "struct A\n  x: Int\nend\n\n"
                               "struct A\n  y: Int\nend\n\n"
                               "def main() -> Nil\nend\n"))
                  'CHECK-REDEFINED-NAME)
    (check-equal? (check-code (main-with "  x: List[Int, Int] = []")) 'CHECK-UNKNOWN-TYPE)
    (check-equal? (check-code (string-append
                               "def f() -> Nil\nend\n\n"
                               "def main() -> Nil\n  x = f\nend\n"))
                  'CHECK-UNKNOWN-NAME)
    (check-ok (string-append
               "def f() -> Nil\nend\n\n"
               "def main() -> Nil\n  f = 1\n  puts(\"ok\")\nend\n")))

  (test-case "calls and constructors"
    (define task
      (string-append
       "struct Task\n  title: String\n  done: Bool\nend\n\n"))
    (check-equal? (check-code (string-append
                               "def f(a: Int) -> Int\n  return a\nend\n\n"
                               "def main() -> Nil\n  x = f(1, 2)\nend\n"))
                  'CHECK-ARITY)
    (check-equal? (check-code
                   (string-append task
                                  "def main() -> Nil\n"
                                  "  t = Task(title: \"x\", done: false, extra: 1)\n"
                                  "end\n"))
                  'CHECK-UNKNOWN-FIELD)
    (check-equal? (check-code
                   (string-append task
                                  "def main() -> Nil\n"
                                  "  t = Task(title: \"x\")\n"
                                  "end\n"))
                  'CHECK-MISSING-FIELD)
    (check-equal? (check-code
                   (string-append task
                                  "def main() -> Nil\n"
                                  "  t = Task(title: \"x\", title: \"y\", done: false)\n"
                                  "end\n"))
                  'CHECK-DUPLICATE-FIELD)
    (check-equal? (check-code
                   (string-append task
                                  "def main() -> Nil\n"
                                  "  t = Task(title: 1, done: false)\n"
                                  "end\n"))
                  'CHECK-TYPE-MISMATCH))

  (test-case "statements"
    (check-equal? (check-code (main-with "  x = 0\n  x = \"s\"")) 'CHECK-TYPE-MISMATCH)
    (check-equal? (check-code (main-with "  x = 0\n  x: Int = 1")) 'CHECK-ANNOTATION-ON-EXISTING)
    (check-equal? (check-code (main-with "  x = 0\n  for x in [1, 2]\n    puts(\"hi\")\n  end"))
                  'CHECK-SHADOWED-NAME)
    (check-equal? (check-code (main-with "  x = 1\n  y = x.name")) 'CHECK-NOT-A-STRUCT)
    (check-equal? (check-code (main-with "  x = 1\n  y = x[0]")) 'CHECK-NOT-A-LIST)
    (check-equal? (check-code (main-with "  for i in 1\n    puts(\"hi\")\n  end"))
                  'CHECK-NOT-A-LIST)
    (check-equal? (check-code (main-with "  x = 1 + 1.5")) 'CHECK-TYPE-MISMATCH)
    (check-equal? (check-code (main-with "  for i in [1, 2]\n    i = 3\n  end"))
                  'CHECK-IMMUTABLE-ASSIGNMENT)
    (check-ok (main-with "  x: List[Int] = []\n  puts(\"ok\")")))

  (test-case "returns and entry point"
    (check-equal? (check-code (string-append
                               "def f(n: Int) -> Int\n"
                               "  if n > 0\n"
                               "    return 1\n"
                               "  end\n"
                               "end\n\n"
                               "def main() -> Nil\nend\n"))
                  'CHECK-MISSING-RETURN)
    (check-equal? (check-code "def f() -> Int\n  return 1\nend\n") 'CHECK-MAIN)
    (check-equal? (check-code (string-append
                               "def main() -> Nil\nend\n\n"
                               "def main() -> Nil\nend\n"))
                  'CHECK-REDEFINED-NAME)
    (check-equal? (check-code "def main(x: Int) -> Nil\nend\n") 'CHECK-MAIN)
    (check-equal? (check-code "def main() -> Int\n  return 1\nend\n") 'CHECK-MAIN))

  (test-case "check diagnostics carry spans"
    (define mismatch (check-text "def main() -> Nil\n  x: Int = \"s\"\nend\n"))
    (check-true (diagnostic? mismatch))
    (check-equal? (diagnostic-code mismatch) 'CHECK-TYPE-MISMATCH)
    (check-equal? (source-position-line (source-span-start (diagnostic-span mismatch))) 2)
    (check-equal? (source-position-column (source-span-start (diagnostic-span mismatch))) 12)

    (define unknown (check-text "def main() -> Nil\n  x = missing\nend\n"))
    (check-true (diagnostic? unknown))
    (check-equal? (diagnostic-code unknown) 'CHECK-UNKNOWN-NAME)
    (check-equal? (source-position-line (source-span-start (diagnostic-span unknown))) 2)
    (check-equal? (source-position-column (source-span-start (diagnostic-span unknown))) 7)

    (define operator (check-text "def main() -> Nil\n  x = 1 + \"a\"\nend\n"))
    (check-true (diagnostic? operator))
    (check-equal? (diagnostic-code operator) 'CHECK-TYPE-MISMATCH)
    (check-equal? (source-position-column (source-span-start (diagnostic-span operator))) 9)))
