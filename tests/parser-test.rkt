#lang racket

(require rackunit
         "../src/ast.rkt"
         "../src/diagnostic.rkt"
         "../src/lexer.rkt"
         "../src/parser.rkt"
         "../src/source.rkt")

(define (parse-text text)
  (parse (lex (source "test.agc" text))))

(define (parse-ok text)
  (define result (parse-text text))
  (if (diagnostic? result)
      (error 'parser-test "expected a program for ~s, got: ~a"
             text (format-diagnostic result))
      result))

(define (parse-code text)
  (define result (parse-text text))
  (if (diagnostic? result)
      (diagnostic-code result)
      (error 'parser-test "expected a diagnostic for ~s, got a program" text)))

(define (parse-expr text)
  (define program (parse-ok (format "def f() -> Int\n  x = ~a\nend\n" text)))
  (define fn (car (program-declarations program)))
  (binding-value (car (function-decl-body fn))))

(module+ test
  (test-case "function references and chained calls retain their spans"
    (define expression (parse-expr "handlers[\"double\"].call(21)"))
    (check-true (invoke? expression))
    (check-true (index-access? (invoke-target expression)))
    (check-equal? (literal-value (car (invoke-args expression))) 21)
    (define reference (parse-expr "&done?"))
    (check-equal? (function-ref-name reference) "done?")
    (check-equal? (source-position-column (source-span-start (node-span reference))) 7)
    (check-equal? (parse-code "def main() -> Nil\n  f = &\nend\n") 'PARSE-UNEXPECTED-TOKEN))
  (test-case "try has unary precedence and a source span"
    (define expression (parse-expr "try ok(1) + 2"))
    (check-true (binary? expression))
    (check-true (try-expr? (binary-left expression)))
    (check-equal? (call-name (try-expr-operand (binary-left expression))) "ok")
    (check-equal? (source-position-column
                   (source-span-start (node-span (binary-left expression)))) 7)
    (check-true (try-expr? (parse-expr "try (ok(1))")))
    (check-equal? (parse-code "def main() -> Nil\n  ready? = true\nend\n")
                  'PARSE-UNEXPECTED-TOKEN))

  (test-case "hello program parses"
    (define program (parse-ok "def main() -> Nil\n  puts(\"hello\")\nend\n"))
    (check-equal? (length (program-declarations program)) 1)
    (define fn (car (program-declarations program)))
    (check-true (function-decl? fn))
    (check-equal? (function-decl-name fn) "main")
    (check-equal? (type-ref-name (function-decl-result fn)) "Nil")
    (check-equal? (length (function-decl-params fn)) 0)
    (define statement (car (function-decl-body fn)))
    (check-true (expr-stmt? statement))
    (check-true (call? (expr-stmt-value statement)))
    (check-equal? (call-name (expr-stmt-value statement)) "puts"))

  (test-case "if/elsif/else parses"
    (define program
      (parse-ok (string-append
                 "def classify(age: Int) -> String\n"
                 "  if age >= 18\n"
                 "    return \"adult\"\n"
                 "  elsif age >= 13\n"
                 "    return \"teen\"\n"
                 "  else\n"
                 "    return \"child\"\n"
                 "  end\n"
                 "end\n")))
    (define fn (car (program-declarations program)))
    (check-equal? (length (function-decl-params fn)) 1)
    (define node (car (function-decl-body fn)))
    (check-true (if-stmt? node))
    (check-equal? (length (if-stmt-branches node)) 2)
    (check-equal? (length (if-stmt-else-body node)) 1))

  (test-case "struct, list literal, constructor, for, and field access parse"
    (define program
      (parse-ok (string-append
                 "struct Todo\n"
                 "  title: String\n"
                 "  done: Bool\n"
                 "end\n"
                 "\n"
                 "def main() -> Nil\n"
                 "  tasks: List[Todo] = [\n"
                 "    Todo(title: \"Probar\", done: false),\n"
                 "    Todo(title: \"Revisar\", done: true)\n"
                 "  ]\n"
                 "  for task in tasks\n"
                 "    if not task.done\n"
                 "      puts(task.title)\n"
                 "    end\n"
                 "  end\n"
                 "end\n")))
    (check-equal? (length (program-declarations program)) 2)
    (define struct (car (program-declarations program)))
    (check-true (struct-decl? struct))
    (check-equal? (length (struct-decl-fields struct)) 2)
    (define main (cadr (program-declarations program)))
    (define binding-node (car (function-decl-body main)))
    (check-true (binding? binding-node))
    (check-equal? (type-ref-name (binding-type binding-node)) "List")
    (check-true (list-lit? (binding-value binding-node)))
    (check-true (for-stmt? (cadr (function-decl-body main)))))

  (test-case "arithmetic precedence and associativity"
    (define product (parse-expr "a + b * c"))
    (check-equal? (binary-op product) 'plus)
    (check-equal? (binary-op (binary-right product)) 'multiply)

    (define difference (parse-expr "a - b - c"))
    (check-equal? (binary-op difference) 'minus)
    (check-equal? (binary-op (binary-left difference)) 'minus)

    (define negated (parse-expr "-a * b"))
    (check-equal? (binary-op negated) 'multiply)
    (check-true (unary? (binary-left negated)))
    (check-equal? (unary-op (binary-left negated)) 'minus)

    (define both (parse-expr "not a and b"))
    (check-equal? (binary-op both) 'and)
    (check-true (unary? (binary-left both)))

    (define mixed (parse-expr "a or b and c"))
    (check-equal? (binary-op mixed) 'or)
    (check-equal? (binary-op (binary-right mixed)) 'and))

  (test-case "postfix access"
    (check-true (field-access? (parse-expr "user.name")))
    (check-true (index-access? (parse-expr "users[0]")))
    (define chained (parse-expr "find_user(1).name"))
    (check-true (field-access? chained))
    (check-true (call? (field-access-target chained))))

  (test-case "calls, constructors, and trailing commas"
    (define no-args (parse-expr "main()"))
    (check-true (call? no-args))
    (check-equal? (call-args no-args) '())

    (define two-args (parse-expr "f(1, 2,)"))
    (check-equal? (length (call-args two-args)) 2)

    (define constructor (parse-expr "Todo(done: false, title: \"x\")"))
    (check-true (construct? constructor))
    (check-equal? (named-arg-name (car (construct-args constructor))) "done")

    (define items (parse-expr "[1, 2,]"))
    (check-true (list-lit? items))
    (check-equal? (length (list-lit-elements items)) 2))

  (test-case "type applications parse"
    (define program
      (parse-ok (string-append
                 "def f(x: List[List[Int]]) -> List[Int]\n"
                 "  y: List[String] = []\n"
                 "  return x\n"
                 "end\n")))
    (define fn (car (program-declarations program)))
    (define param-node (param-type (car (function-decl-params fn))))
    (check-equal? (type-ref-name param-node) "List")
    (define inner (car (type-ref-args param-node)))
    (check-equal? (type-ref-name inner) "List")
    (check-equal? (type-ref-name (car (type-ref-args inner))) "Int")
    (define binding-node (car (function-decl-body fn)))
    (check-equal? (type-ref-name (binding-type binding-node)) "List")
    (check-true (list-lit? (binding-value binding-node))))

  (test-case "nodes carry source spans"
    (define program (parse-ok "def main() -> Nil\n  puts(\"hello\")\nend\n"))
    (define fn (car (program-declarations program)))
    (check-equal? (source-position-line (source-span-start (function-decl-span fn))) 1)
    (check-equal? (source-position-column (source-span-start (function-decl-span fn))) 1)
    (define node (expr-stmt-value (car (function-decl-body fn))))
    (check-equal? (source-position-line (source-span-start (call-span node))) 2)
    (check-equal? (source-position-column (source-span-start (call-span node))) 3)
    (check-equal? (source-span-end (call-span node)) (source-position 33 2 16))
    (define composite (parse-expr "a + b * c"))
    (check-equal? (source-span-start (binary-span composite)) (source-position 21 2 7))
    (check-equal? (source-span-end (binary-span composite)) (source-position 30 2 16))
    (check-equal? (source-span-start (binary-op-span composite)) (source-position 23 2 9))
    (check-equal? (source-span-end (binary-op-span composite)) (source-position 24 2 10))
    (define negated (parse-expr "-a"))
    (check-equal? (source-span-start (unary-op-span negated)) (source-position 21 2 7)))

  (test-case "empty input parses to an empty program"
    (check-equal? (program-declarations (parse-ok "")) '()))

  (test-case "while, reassignment, and bare return parse"
    (define program
      (parse-ok (string-append
                 "def countdown(n: Int) -> Nil\n"
                 "  count = 0\n"
                 "  while count < n\n"
                 "    count = count + 1\n"
                 "  end\n"
                 "  return\n"
                 "end\n")))
    (define fn (car (program-declarations program)))
    (define body (function-decl-body fn))
    (check-true (binding? (car body)))
    (check-true (while-stmt? (cadr body)))
    (check-true (return-stmt? (caddr body)))
    (check-false (return-stmt-value (caddr body))))

  (test-case "a comparison chain is a located diagnostic"
    (define result (parse-text "def f() -> Int\n  return a < b < c\nend\n"))
    (check-true (diagnostic? result))
    (check-equal? (diagnostic-code result) 'PARSE-CHAINED-COMPARISON)
    (check-equal? (source-position-line (source-span-start (diagnostic-span result))) 2)
    (check-equal? (source-position-column (source-span-start (diagnostic-span result))) 16))

  (test-case "invalid syntax is rejected"
    (check-equal? (parse-code "def f() -> Bool\n  return a == b == c\nend\n")
                  'PARSE-CHAINED-COMPARISON)
    (check-equal? (parse-code "puts(\"hello\")\n") 'PARSE-TOP-LEVEL-STATEMENT)
    (check-equal? (parse-code "age: Int = \"25\"\n") 'PARSE-TOP-LEVEL-STATEMENT)
    (check-equal? (parse-code "def f() -> Int\n  return 1\n") 'PARSE-UNCLOSED-BLOCK)
    (check-equal? (parse-code "def f() -> Nil\n  x = Foo\nend\n") 'PARSE-UNEXPECTED-TOKEN)
    (check-equal? (parse-code "def f() -> Nil\n  x[0] = 1\nend\n")
                  'PARSE-INVALID-ASSIGNMENT-TARGET)
    (check-equal? (parse-code "def f() -> Nil\n  x.y = 1\nend\n")
                  'PARSE-INVALID-ASSIGNMENT-TARGET)
    (check-equal? (parse-code "def f() -> Nil\n  x = 1 y = 2\nend\n")
                  'PARSE-UNEXPECTED-TOKEN)
    (check-equal? (parse-code "def f() -> Nil\n  puts \"hello\"\nend\n")
                  'PARSE-UNEXPECTED-TOKEN))

  (test-case "map literals and builtin module calls"
    (define literal (parse-expr "{\n  \"a\": 1,\n  \"b\": 2,\n}"))
    (check-true (map-lit? literal))
    (check-equal? (length (map-lit-entries literal)) 2)
    (check-true (map-lit? (parse-expr "{}")))
    (define put (parse-expr "Map.put(m, \"a\", 1)"))
    (check-true (call? put))
    (check-equal? (call-name put) "Map.put")
    (check-equal? (length (call-args put)) 3))

  (test-case "comparison mixed with equality is allowed"
    (define node (parse-expr "a < b == c < d"))
    (check-equal? (binary-op node) 'equal)
    (check-equal? (binary-op (binary-left node)) 'less)
    (check-equal? (binary-op (binary-right node)) 'less)))
