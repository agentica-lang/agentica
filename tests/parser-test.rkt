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
  (define program (parse-ok (format "def f() -> Int\n  x = ~a\nend\n\n" text)))
  (define fn (car (program-declarations program)))
  (binding-value (car (function-decl-body fn))))

(module+ test
  (test-case "ranges bind loosest and do not chain"
    (define exclusive (parse-expr "0...n + 1"))
    (check-equal? (binary-op exclusive) 'dot-dot-dot)
    (check-equal? (binary-op (binary-right exclusive)) 'plus)
    (define inclusive (parse-expr "a or b..c"))
    (check-equal? (binary-op inclusive) 'dot-dot)
    (check-equal? (binary-op (binary-left inclusive)) 'or)
    (check-equal? (source-position-column (source-span-start (binary-op-span inclusive))) 13)
    (define grouped (parse-expr "(1..5).to_a"))
    (check-equal? (binary-op (field-access-target grouped)) 'dot-dot)
    (check-true (for-stmt? (car (function-decl-body
                                 (car (program-declarations
                                       (parse-ok "def main() -> Void\n  for i in 0...3 do\n    puts(i)\n  end\nend\n\n")))))))
    (check-equal? (parse-code "def f() -> Void\n  x = 1..2..3\nend\n\n") 'PARSE-UNEXPECTED-TOKEN)
    (check-equal? (parse-code "def f() -> Void\n  x = 1..\n  2\nend\n\n") 'PARSE-UNEXPECTED-TOKEN))

  (test-case "function references and chained calls retain their spans"
    (define expression (parse-expr "handlers[\"double\"].call(21)"))
    (check-true (invoke? expression))
    (check-true (index-access? (invoke-target expression)))
    (check-equal? (literal-value (car (invoke-args expression))) 21)
    (define reference (parse-expr "&done?"))
    (check-equal? (function-ref-name reference) "done?")
    (check-equal? (source-position-column (source-span-start (node-span reference))) 7)
    (check-equal? (parse-code "def main() -> Void\n  f = &\nend\n\n") 'PARSE-UNEXPECTED-TOKEN))
  (test-case "try has unary precedence and a source span"
    (define expression (parse-expr "try ok(1) + 2"))
    (check-true (binary? expression))
    (check-true (try-expr? (binary-left expression)))
    (check-equal? (call-name (try-expr-operand (binary-left expression))) "ok")
    (check-equal? (source-position-column
                   (source-span-start (node-span (binary-left expression)))) 7)
    (check-true (try-expr? (parse-expr "try (ok(1))")))
    (check-equal? (parse-code "def main() -> Void\n  ready? = true\nend\n\n")
                  'PARSE-UNEXPECTED-TOKEN))

  (test-case "Ruby operators share the not/and/or nodes and compound assignment desugars"
    (define expression (parse-expr "!a && b || c"))
    (check-equal? (binary-op expression) 'or)
    (check-equal? (binary-op (binary-left expression)) 'and)
    (check-equal? (unary-op (binary-left (binary-left expression))) 'not)
    (define program (parse-ok "def main() -> Void\n  total = 1\n  total -= 2 * 3\nend\n\n"))
    (define statement (cadr (function-decl-body (car (program-declarations program)))))
    (check-true (binding? statement))
    (check-false (binding-type statement))
    (define value (binding-value statement))
    (check-equal? (binary-op value) 'minus)
    (check-equal? (name-ref-name (binary-left value)) "total")
    (check-equal? (binary-op (binary-right value)) 'multiply)
    (check-equal? (source-position-column (source-span-start (binary-op-span value))) 9)
    (for ([body '("  xs[0] += 1" "  f() *= 2" "  1 %= 2")])
      (check-equal? (parse-code (format "def main() -> Void\n~a\nend\n\n" body))
                    'PARSE-INVALID-ASSIGNMENT-TARGET)))

  (test-case "interpolation keeps text and expression parts in order"
    (define expression (parse-expr "\"a#{n + 1}#{m}\""))
    (check-true (interpolation? expression))
    (define parts (interpolation-parts expression))
    (check-equal? (car parts) "a")
    (check-true (binary? (cadr parts)))
    (check-equal? (name-ref-name (caddr parts)) "m")
    (check-equal? (length parts) 3)
    (check-equal? (source-position-column (source-span-start (node-span expression))) 7)
    (check-equal? (parse-code "def main() -> Void\n  x = \"#{1 2}\"\nend\n\n") 'PARSE-UNEXPECTED-TOKEN)
    (check-equal? (parse-code "def main() -> Void\n  x = \"#{}\"\nend\n\n") 'PARSE-UNEXPECTED-TOKEN)
    (define empty-part (parse-text "def main() -> Void\n  x = \"a #{} b\"\nend\n\n"))
    (check-equal? (source-position-column (source-span-start (diagnostic-span empty-part))) 12))

  (test-case "blocks attach to calls as the last argument"
    (define mapped (parse-expr "xs.map do |x, y: Int|\n    x\n  end"))
    (check-true (method-call? mapped))
    (define block (car (method-call-args mapped)))
    (check-true (block-lit? block))
    (check-equal? (map block-param-name (block-lit-params block)) '("x" "y"))
    (check-false (block-param-type (car (block-lit-params block))))
    (check-equal? (type-ref-name (block-param-type (cadr (block-lit-params block)))) "Int")
    (check-equal? (source-position-line (source-span-end (node-span mapped))) 4)
    (define one-line (parse-expr "List.reduce(xs, 0) do |a, b| a + b end"))
    (check-equal? (length (call-args one-line)) 3)
    (check-true (expr-stmt? (car (block-lit-body (caddr (call-args one-line))))))
    (check-equal? (block-lit-params (car (call-args (parse-expr "f() do\n    return 1\n  end")))) '())
    (define scrutinee
      (parse-ok "def main() -> Void\n  case f() do\n    _ ->\n      puts(\"a\")\n  end\n  case (xs.map do |x| x end) do\n    _ ->\n      puts(\"b\")\n  end\nend\n\n"))
    (check-true (call? (case-stmt-value (car (function-decl-body (car (program-declarations scrutinee)))))))
    (check-equal? (parse-code "def main() -> Void\n  xs.each do || puts(\"a\") end\nend\n") 'PARSE-UNEXPECTED-TOKEN)
    (check-equal? (parse-code "def main() -> Void\n  x = 1 do\n  end\nend\n") 'PARSE-UNEXPECTED-TOKEN)
    (check-equal? (parse-code "def main() -> Void\n  xs.each do |x|\n    if x\n      puts(x) end\n  end\nend\n")
                  'PARSE-UNEXPECTED-TOKEN)
    (check-equal? (parse-code "def main() -> Void\n  xs.each do |x|\n    puts(x)\n") 'PARSE-UNCLOSED-BLOCK))

  (test-case "Ruby headers, one-line case arms and module calls without parentheses"
    (define program
      (parse-ok (string-append
                 "def main() -> Void\n  while !IO.eof? do\n    line = IO.gets!\n  end\n"
                 "  for x in xs.reverse do\n    puts(x)\n  end\n"
                 "  case n\n    1 -> puts(\"one\")\n    _ ->\n      puts(\"other\")\n      puts(\"more\")\n  end\nend\n")))
    (define body (function-decl-body (car (program-declarations program))))
    (define loop (car body))
    (check-true (call? (unary-operand (while-stmt-condition loop))))
    (check-equal? (call-args (unary-operand (while-stmt-condition loop))) '())
    (check-true (call? (binding-value (car (while-stmt-body loop)))))
    (check-true (field-access? (for-stmt-iterable (cadr body))))
    (define arms (case-stmt-arms (caddr body)))
    (check-equal? (map (lambda (arm) (length (case-arm-body arm))) arms) '(1 2)))

  (test-case "break and next are statements on their own line"
    (define body
      (function-decl-body
       (car (program-declarations
             (parse-ok "def main() -> Void\n  while true\n    next\n    break\n  end\n  next = 1\nend\n")))))
    (check-equal? (map loop-control-kind (while-stmt-body (car body))) '(next break))
    (check-equal? (source-position-line (source-span-start (loop-control-span (cadr (while-stmt-body (car body)))))) 4)
    (check-true (binding? (cadr body))))

  (test-case "Result spellings, bare gets and nullary variants through an alias"
    (define body
      (function-decl-body
       (car (program-declarations
             (parse-ok (string-append
                        "def main() -> Void\n  a = Result.Ok(1)\n  b = Result.Err(\"x\")\n  c = gets!\n"
                        "  d = M.Shape.Dot\n  case a\n    ok(v) -> puts(v)\n    error(_) -> puts(\"e\")\n  end\nend\n"))))))
    (check-equal? (call-name (binding-value (car body))) "ok")
    (check-equal? (call-name (binding-value (cadr body))) "error")
    (check-equal? (call-name (binding-value (caddr body))) "gets!")
    (check-equal? (call-args (binding-value (caddr body))) '())
    (check-true (enum-constructor? (binding-value (cadddr body))))
    (check-equal? (enum-constructor-args (binding-value (cadddr body))) '())
    (define arms (case-stmt-arms (list-ref body 4)))
    (check-equal? (map (lambda (arm) (variant-pattern-variant-name (case-arm-pattern arm))) arms) '("Ok" "Err"))
    (check-equal? (map (lambda (arm) (variant-pattern-bindings (case-arm-pattern arm))) arms) '(("v") (#f))))

  (test-case "habits from other languages get a parse hint"
    (for ([entry '(("  case x\n    when 1\n      puts(\"a\")\n  end" "->")
                   ("  let x = 5" "x = 5")
                   ("  var x = 5" "x = 5")
                   ("  match x" "case")
                   ("  if x then\n    puts(\"a\")\n  end" "then")
                   ("  f = fn(x: Int) -> Int" "block")
                   ("  f = lambda do |x|\n    x\n  end" "lambdas")
                   ("  f = do |x|\n    x\n  end" "lambdas")
                   ("  ys = run do |x| x end" "run\\(\\)")
                   ("  if x > 0 do\n    puts(\"a\")\n  end" "newline, not do")
                   ("  loop do\n    puts(\"a\")\n  end" "while true")
                   ("  break if x > 3" "no if modifiers")
                   ("  puts(\"a\") if x" "if cond \\.\\.\\. end")
                   ("  n = String.length \"abc\"" "String\\.length\\(")
                   ("  case r\n    ok() -> puts(\"a\")\n  end" "ok\\(_\\)"))])
      (define problem (parse-text (format "def main() -> Void\n~a\nend\n" (car entry))))
      (check-equal? (diagnostic-code problem) 'PARSE-UNEXPECTED-TOKEN (car entry))
      (check-equal? (source-position-line (source-span-start (diagnostic-span problem)))
                    (if (regexp-match? #rx"^  case" (car entry)) 3 2)
                    (car entry))
      (check-regexp-match (pregexp (cadr entry)) (diagnostic-help problem) (car entry))))

  (test-case "declarations need a blank line after their end"
    (define problem (parse-text "struct A\n  n: Int\nend\ndef main() -> Void\nend\n\n"))
    (check-equal? (diagnostic-code problem) 'PARSE-MISSING-BLANK-LINE)
    (check-equal? (source-position-line (source-span-start (diagnostic-span problem))) 4)
    (parse-ok "import \"a.agc\" as A\ndef f() -> Void\nend\n# note\ndef main() -> Void\nend")
    (check-equal? (parse-code "def f() -> Void\nend\nexport def main() -> Void\nend\n\n") 'PARSE-MISSING-BLANK-LINE)
    (check-equal? (parse-code "enum E\n  A\nend\nimport \"a.agc\" as A\n") 'PARSE-MISSING-BLANK-LINE)
    (check-equal? (parse-code "def f() -> Void\nend\nend\n") 'PARSE-TOP-LEVEL-STATEMENT)
    (check-equal? (parse-code "def f() -> Void\nend\nputs(1)\n") 'PARSE-TOP-LEVEL-STATEMENT))

  (test-case "elif and else if point to elsif"
    (for ([text '("def main() -> Void\n  if true\n    x = 1\n  elif false\n    x = 2\n  end\nend\n"
                  "def main() -> Void\n  if true\n    x = 1\n  elseif false\n    x = 2\n  end\nend\n"
                  "def main() -> Void\n  if true\n    x = 1\n  else if false\n    x = 2\n  end\n  end\nend\n")])
      (define problem (parse-text text))
      (check-equal? (diagnostic-code problem) 'PARSE-UNEXPECTED-TOKEN text)
      (check-equal? (source-position-line (source-span-start (diagnostic-span problem))) 4 text)
      (check-regexp-match #rx"elsif" (diagnostic-help problem) text)))

  (test-case "hello program parses"
    (define program (parse-ok "def main() -> Void\n  puts(\"hello\")\nend\n\n"))
    (check-equal? (length (program-declarations program)) 1)
    (define fn (car (program-declarations program)))
    (check-true (function-decl? fn))
    (check-equal? (function-decl-name fn) "main")
    (check-equal? (type-ref-name (function-decl-result fn)) "Void")
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
                 "end\n\n")))
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
                 "end\n\n"
                 "\n"
                 "def main() -> Void\n"
                 "  tasks: List[Todo] = [\n"
                 "    Todo(title: \"Probar\", done: false),\n"
                 "    Todo(title: \"Revisar\", done: true)\n"
                 "  ]\n"
                 "  for task in tasks\n"
                 "    if not task.done\n"
                 "      puts(task.title)\n"
                 "    end\n"
                 "  end\n"
                 "end\n\n")))
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
                 "end\n\n")))
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
    (define program (parse-ok "def main() -> Void\n  puts(\"hello\")\nend\n\n"))
    (define fn (car (program-declarations program)))
    (check-equal? (source-position-line (source-span-start (function-decl-span fn))) 1)
    (check-equal? (source-position-column (source-span-start (function-decl-span fn))) 1)
    (define node (expr-stmt-value (car (function-decl-body fn))))
    (check-equal? (source-position-line (source-span-start (call-span node))) 2)
    (check-equal? (source-position-column (source-span-start (call-span node))) 3)
    (check-equal? (source-span-end (call-span node)) (source-position 34 2 16))
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
                 "def countdown(n: Int) -> Void\n"
                 "  count = 0\n"
                 "  while count < n\n"
                 "    count = count + 1\n"
                 "  end\n"
                 "  return\n"
                 "end\n\n")))
    (define fn (car (program-declarations program)))
    (define body (function-decl-body fn))
    (check-true (binding? (car body)))
    (check-true (while-stmt? (cadr body)))
    (check-true (return-stmt? (caddr body)))
    (check-false (return-stmt-value (caddr body))))

  (test-case "a comparison chain is a located diagnostic"
    (define result (parse-text "def f() -> Int\n  return a < b < c\nend\n\n"))
    (check-true (diagnostic? result))
    (check-equal? (diagnostic-code result) 'PARSE-CHAINED-COMPARISON)
    (check-equal? (source-position-line (source-span-start (diagnostic-span result))) 2)
    (check-equal? (source-position-column (source-span-start (diagnostic-span result))) 16))

  (test-case "invalid syntax is rejected"
    (check-equal? (parse-code "def f() -> Bool\n  return a == b == c\nend\n\n")
                  'PARSE-CHAINED-COMPARISON)
    (check-equal? (parse-code "puts(\"hello\")\n") 'PARSE-TOP-LEVEL-STATEMENT)
    (check-equal? (parse-code "age: Int = \"25\"\n") 'PARSE-TOP-LEVEL-STATEMENT)
    (check-equal? (parse-code "def f() -> Int\n  return 1\n") 'PARSE-UNCLOSED-BLOCK)
    (check-true (type-expression? (parse-expr "Foo")))
    (check-equal? (parse-code "def f() -> Void\n  x[0] = 1\nend\n\n")
                  'PARSE-INVALID-ASSIGNMENT-TARGET)
    (check-equal? (parse-code "def f() -> Void\n  x.y = 1\nend\n\n")
                  'PARSE-INVALID-ASSIGNMENT-TARGET)
    (check-equal? (parse-code "def f() -> Void\n  x = 1 y = 2\nend\n\n")
                  'PARSE-UNEXPECTED-TOKEN)
    (check-equal? (parse-code "def f() -> Void\n  puts \"hello\"\nend\n\n")
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
    (check-equal? (binary-op (binary-right node)) 'less))

  (test-case "generic enum declarations, constructors, and case patterns parse"
    (define program
      (parse-ok (string-append
                 "enum Option[T]\n  Some(T)\n  None\nend\n\n"
                 "\ndef main() -> Void\n"
                 "  value = Option.Some(3)\n"
                 "  case value do\n"
                 "    Option.Some(item) ->\n      puts(item)\n"
                 "    Option.None ->\n      puts(0)\n"
                 "  end\nend\n\n")))
    (define enum (car (program-declarations program)))
    (check-true (enum-decl? enum))
    (check-equal? (enum-decl-type-parameters enum) '("T"))
    (check-equal? (length (enum-decl-variants enum)) 2)
    (define main (cadr (program-declarations program)))
    (check-true (enum-constructor? (binding-value (car (function-decl-body main)))))
    (define matched (cadr (function-decl-body main)))
    (check-true (case-stmt? matched))
    (check-true (variant-pattern? (case-arm-pattern (car (case-stmt-arms matched)))))
    (check-equal? (variant-pattern-bindings (case-arm-pattern (car (case-stmt-arms matched))))
                  '("item"))
    (check-true (variant-pattern? (case-arm-pattern (cadr (case-stmt-arms matched)))))
    (check-equal? (variant-pattern-bindings (case-arm-pattern (cadr (case-stmt-arms matched)))) '()))

  (test-case "underscore discards direct enum payloads and imported patterns keep qualification"
    (define matched
      (parse-ok (string-append
                 "def main() -> Void\n  case value do\n"
                 "    Domain.Option.Some(_, other) ->\n      puts(other)\n"
                 "    _ ->\n      puts(0)\n  end\nend\n\n")))
    (define arms (case-stmt-arms (car (function-decl-body (car (program-declarations matched))))))
    (define pattern (case-arm-pattern (car arms)))
    (check-equal? (variant-pattern-enum-name pattern) "Domain.Option")
    (check-equal? (variant-pattern-bindings pattern) (list #f "other"))
    (check-true (wildcard-pattern? (case-arm-pattern (cadr arms))))))
