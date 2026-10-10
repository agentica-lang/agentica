#lang racket

(require "ast.rkt"
         "diagnostic.rkt"
         "source.rkt"
         "token.rkt")

(provide parse)

(define compound-operators
  (hasheq 'plus-assign 'plus 'minus-assign 'minus 'multiply-assign 'multiply
          'divide-assign 'divide 'modulo-assign 'modulo))

(define (parse tokens)
  (define toks (list->vector tokens))
  (define count (vector-length toks))
  (define pos 0)
  (define last-consumed #f)

  (define (current)
    (if (< pos count) (vector-ref toks pos) (vector-ref toks (sub1 count))))

  (define (peek-token distance)
    (define at (+ pos distance))
    (if (< at count) (vector-ref toks at) (vector-ref toks (sub1 count))))

  (define (kind? expected)
    (eq? (token-kind (current)) expected))

  (define (advance!)
    (define token (current))
    (when (< pos (sub1 count))
      (set! pos (add1 pos)))
    (set! last-consumed token)
    token)

  (define (describe token)
    (define lexeme (token-lexeme token))
    (cond
      [(not lexeme) (format "~a" (token-kind token))]
      [(equal? lexeme "") (format "~a" (token-kind token))]
      [(eq? (token-kind token) 'NL) "a newline"]
      [else (format "~s" lexeme)]))

  (define (span-from start-token)
    (define start-span (token-span start-token))
    (define end-span (token-span last-consumed))
    (source-span (source-span-source start-span)
                 (source-span-start start-span)
                 (source-span-end end-span)))

  (define (skip-newlines!)
    (let loop ()
      (when (kind? 'NL)
        (advance!)
        (loop))))

  (let/ec return
    (define (bail code message token)
      (return (diagnostic code message (token-span token))))

    (define (expect expected description [suffix? #f])
      (if (and (kind? expected)
               (not (and (eq? expected 'name)
                         (not suffix?)
                         (regexp-match? #px"[?!]$" (token-lexeme (current))))))
          (advance!)
          (bail 'PARSE-UNEXPECTED-TOKEN
                (format "expected ~a, found ~a" description (describe (current)))
                (current))))

    (define (expect-end)
      (cond
        [(kind? 'end) (advance!)]
        [(kind? 'EOF) (bail 'PARSE-UNCLOSED-BLOCK "unclosed block, expected \"end\"" (current))]
        [else (bail 'PARSE-UNEXPECTED-TOKEN
                    (format "expected \"end\", found ~a" (describe (current)))
                    (current))]))

    ;; Declarations --------------------------------------------------------

    (define (parse-program)
      (define start (current))
      (define declarations
        (let loop ([acc '()])
          (skip-newlines!)
          (cond
            [(kind? 'EOF) (reverse acc)]
            [(kind? 'import)
             (define begin (advance!))
             (define path (expect 'string "an import path"))
             (define as-token (expect 'name "as"))
             (unless (equal? (token-lexeme as-token) "as")
               (bail 'PARSE-UNEXPECTED-TOKEN "expected as" as-token))
             (define alias (expect 'type-name "a module alias"))
             (expect 'NL "a newline after import")
             (loop (cons (import-decl (token-value path) (token-lexeme alias) (span-from begin)) acc))]
            [(kind? 'export)
             (define begin (advance!))
             (define declaration
               (cond [(kind? 'def) (parse-function-decl)]
                     [(kind? 'struct) (parse-struct-decl)]
                     [(kind? 'enum) (parse-enum-decl)]
                     [else (bail 'PARSE-UNEXPECTED-TOKEN "export requires def, struct, or enum" (current))]))
             (loop (cons (export-decl declaration (span-from begin)) acc))]
            [(kind? 'def) (loop (cons (parse-function-decl) acc))]
            [(kind? 'struct) (loop (cons (parse-struct-decl) acc))]
            [(kind? 'enum) (loop (cons (parse-enum-decl) acc))]
            [else
             (bail 'PARSE-TOP-LEVEL-STATEMENT
                   (format "expected a top-level declaration (def, struct, enum, or import), found ~a"
                           (describe (current)))
                   (current))])))
      (program declarations (span-from start)))

    (define (parse-function-decl)
      (define start (expect 'def "def"))
      (define name (expect 'name "a function name" #t))
      (expect 'left-paren "\"(\"")
      (define params (parse-parameters))
      (expect 'right-paren "\")\"")
      (expect 'arrow "\"->\"")
      (define result (parse-type))
      (expect 'NL "a newline after the function signature")
      (define body (parse-block))
      (expect-end)
      (expect 'NL "a newline after end")
      (function-decl (token-lexeme name) params result body (span-from start)))

    (define (parse-parameters)
      (if (kind? 'right-paren)
          '()
          (let loop ([acc (list (parse-parameter))])
            (cond
              [(kind? 'comma)
               (advance!)
               (if (kind? 'right-paren)
                   (reverse acc)
                   (loop (cons (parse-parameter) acc)))]
              [else (reverse acc)]))))

    (define (parse-parameter)
      (define start (expect 'name "a parameter name"))
      (expect 'colon "\":\"")
      (define type (parse-type))
      (param (token-lexeme start) type (span-from start)))

    (define (parse-type)
      (define start (expect 'type-name "a type name"))
      (define name
        (if (kind? 'dot)
            (begin (advance!)
                   (string-append (token-lexeme start) "."
                                  (token-lexeme (expect 'type-name "an imported type name"))))
            (token-lexeme start)))
      (define arguments
        (if (kind? 'left-bracket)
            (let ()
              (advance!)
              (define first (parse-type))
              (define rest
                (let loop ([acc '()])
                  (cond
                    [(kind? 'comma) (advance!) (loop (cons (parse-type) acc))]
                    [else (reverse acc)])))
              (expect 'right-bracket "\"]\"")
              (cons first rest))
            '()))
      (type-ref name arguments (span-from start)))

    (define (parse-struct-decl)
      (define start (expect 'struct "struct"))
      (define name (expect 'type-name "a struct name"))
      (expect 'NL "a newline after the struct name")
      (define fields
        (let loop ([acc '()])
          (skip-newlines!)
          (cond
            [(or (kind? 'end) (kind? 'EOF)) (reverse acc)]
            [(kind? 'name) (loop (cons (parse-field-decl) acc))]
            [else (bail 'PARSE-UNEXPECTED-TOKEN
                        (format "expected a field name or \"end\", found ~a"
                                (describe (current)))
                        (current))])))
      (expect-end)
      (expect 'NL "a newline after end")
      (struct-decl (token-lexeme name) fields (span-from start)))

    (define (parse-field-decl)
      (define start (expect 'name "a field name"))
      (expect 'colon "\":\"")
      (define type (parse-type))
      (expect 'NL "a newline after the field")
      (field-decl (token-lexeme start) type (span-from start)))

    (define (parse-enum-decl)
      (define start (expect 'enum "enum"))
      (define name (expect 'type-name "an enum name"))
      (define type-parameters
        (if (kind? 'left-bracket)
            (let ()
              (advance!)
              (define first (token-lexeme (expect 'type-name "a type parameter")))
              (define rest
                (let loop ([acc '()])
                  (if (kind? 'comma)
                      (begin
                        (advance!)
                        (loop (cons (token-lexeme (expect 'type-name "a type parameter")) acc)))
                      (reverse acc))))
              (expect 'right-bracket "]")
              (cons first rest))
            '()))
      (expect 'NL "a newline after the enum name")
      (define variants
        (let loop ([acc '()])
          (skip-newlines!)
          (cond
            [(or (kind? 'end) (kind? 'EOF)) (reverse acc)]
            [(kind? 'type-name)
             (define variant-start (advance!))
             (define payload-types
               (if (kind? 'left-paren)
                   (let ()
                     (advance!)
                     (define first (parse-type))
                     (define rest
                       (let payload-loop ([items '()])
                         (if (kind? 'comma)
                             (begin
                               (advance!)
                               (payload-loop (cons (parse-type) items)))
                             (reverse items))))
                     (expect 'right-paren ")")
                     (cons first rest))
                   '()))
             (expect 'NL "a newline after the enum variant")
             (loop (cons (enum-variant (token-lexeme variant-start) payload-types
                                       (span-from variant-start))
                         acc))]
            [else
             (bail 'PARSE-UNEXPECTED-TOKEN
                   (format "expected an enum variant or end, found ~a" (describe (current)))
                   (current))])))
      (when (null? variants)
        (bail 'PARSE-UNEXPECTED-TOKEN "an enum must declare at least one variant" (current)))
      (expect-end)
      (expect 'NL "a newline after end")
      (enum-decl (token-lexeme name) type-parameters variants (span-from start)))

    ;; Statements ----------------------------------------------------------

    (define (token-at index)
      (vector-ref toks (min index (sub1 count))))

    (define (case-arm-start?)
      (define (kind-at index) (token-kind (token-at index)))
      (define (variant-end index)
        (let loop ([at (add1 index)] [segments 1])
          (if (eq? (kind-at at) 'dot)
              (and (< segments 3)
                   (eq? (kind-at (add1 at)) 'type-name)
                   (loop (+ at 2) (add1 segments)))
              (and (>= segments 2)
                   (if (eq? (kind-at at) 'left-paren)
                       (let binder-loop ([cursor (add1 at)])
                         (and (eq? (kind-at cursor) 'name)
                              (if (eq? (kind-at (add1 cursor)) 'comma)
                                  (binder-loop (+ cursor 2))
                                  (and (eq? (kind-at (add1 cursor)) 'right-paren)
                                       (+ cursor 2)))))
                       at)))))
      (define start pos)
      (define pattern-end
        (case (kind-at start)
          [(name) (and (equal? (token-lexeme (token-at start)) "_") (add1 start))]
          [(integer float string true false nil) (add1 start)]
          [(minus) (and (memq (kind-at (add1 start)) '(integer float)) (+ start 2))]
          [(type-name) (variant-end start)]
          [else #f]))
      (and pattern-end
           (eq? (kind-at pattern-end) 'arrow)
           (eq? (kind-at (add1 pattern-end)) 'NL)))

    (define (parse-case-pattern)
      (define start (current))
      (case (token-kind start)
        [(name)
         (if (equal? (token-lexeme start) "_")
             (begin (advance!) (wildcard-pattern (token-span start)))
             (bail 'PARSE-UNEXPECTED-TOKEN "expected a pattern" start))]
        [(integer float string true false nil)
         (advance!)
         (literal-pattern (case (token-kind start)
                            [(true) #t]
                            [(false) #f]
                            [(nil) 'nil]
                            [else (token-value start)])
                          (token-span start))]
        [(minus)
         (advance!)
         (define number (current))
         (unless (memq (token-kind number) '(integer float))
           (bail 'PARSE-UNEXPECTED-TOKEN "expected a number after - in a pattern" number))
         (advance!)
         (literal-pattern (- (token-value number)) (span-from start))]
        [(type-name)
         (define first (advance!))
         (expect 'dot "a dot between an enum and variant")
         (define second (expect 'type-name "a variant name"))
         (define enum-name (token-lexeme first))
         (define variant-name (token-lexeme second))
         (when (kind? 'dot)
           (advance!)
           (set! enum-name (string-append enum-name "." variant-name))
           (set! variant-name (token-lexeme (expect 'type-name "a variant name"))))
         (define bindings
           (if (kind? 'left-paren)
               (let ()
                 (advance!)
                 (when (kind? 'right-paren)
                   (bail 'PARSE-UNEXPECTED-TOKEN "use a nullary variant pattern without parentheses" (current)))
                 (define first-binding-token (expect 'name "a pattern binding or _"))
                 (define first-binding
                   (and (not (equal? (token-lexeme first-binding-token) "_"))
                        (token-lexeme first-binding-token)))
                 (define rest
                   (let loop ([acc '()])
                     (if (kind? 'comma)
                         (let ()
                           (advance!)
                           (define binding-token (expect 'name "a pattern binding or _"))
                           (loop (cons (and (not (equal? (token-lexeme binding-token) "_"))
                                            (token-lexeme binding-token))
                                       acc)))
                         (reverse acc))))
                 (expect 'right-paren ")")
                 (cons first-binding rest))
               '()))
         (variant-pattern enum-name variant-name bindings (span-from start))]
        [else (bail 'PARSE-UNEXPECTED-TOKEN "expected a pattern" start)]))

    (define (parse-case-body)
      (let loop ([acc '()])
        (skip-newlines!)
        (cond
          [(or (kind? 'end) (case-arm-start?)) (reverse acc)]
          [(kind? 'EOF)
           (bail 'PARSE-UNCLOSED-BLOCK "unclosed case block, expected end" (current))]
          [else (loop (cons (parse-statement) acc))])))

    (define (parse-case)
      (define start (expect 'case "case"))
      (define value (parse-expression))
      (expect 'do "do")
      (expect 'NL "a newline after do")
      (define arms
        (let loop ([acc '()])
          (skip-newlines!)
          (cond
            [(kind? 'end)
             (when (null? acc)
               (bail 'PARSE-UNEXPECTED-TOKEN "case requires at least one arm" (current)))
             (reverse acc)]
            [(kind? 'EOF)
             (bail 'PARSE-UNCLOSED-BLOCK "unclosed case block, expected end" (current))]
            [else
             (define arm-start (current))
             (define pattern (parse-case-pattern))
             (expect 'arrow "->")
             (expect 'NL "a newline after a case arm")
             (define body (parse-case-body))
             (loop (cons (case-arm pattern body (span-from arm-start)) acc))])))
      (expect-end)
      (expect 'NL "a newline after end")
      (case-stmt value arms (span-from start)))

    (define (parse-block)
      (let loop ([acc '()])
        (skip-newlines!)
        (cond
          [(or (kind? 'end) (kind? 'elsif) (kind? 'else) (kind? 'EOF)) (reverse acc)]
          [else (loop (cons (parse-statement) acc))])))

    (define (parse-statement)
      (case (token-kind (current))
        [(if) (parse-if)]
        [(while) (parse-while)]
        [(for) (parse-for)]
        [(case) (parse-case)]
        [else (parse-simple-statement)]))

    (define (parse-simple-statement)
      (cond
        [(kind? 'return)
         (define start (advance!))
         (define value (if (kind? 'NL) #f (parse-expression)))
         (expect 'NL "a newline after the statement")
         (return-stmt value (span-from start))]
        [(and (kind? 'name) (memq (token-kind (peek-token 1)) '(assign colon)))
         (parse-binding)]
        [(and (kind? 'name) (hash-ref compound-operators (token-kind (peek-token 1)) #f))
         (parse-compound-assignment)]
        [else
         (define start (current))
         (define value (parse-expression))
         (when (or (kind? 'assign) (hash-ref compound-operators (token-kind (current)) #f))
           (bail 'PARSE-INVALID-ASSIGNMENT-TARGET
                 (if (index-access? value)
                     "the core only assigns to a plain name; lists and maps are immutable, build a new value instead (for a map, Map.put(map, key, value))"
                     "the core only assigns to a plain name")
                 (current)))
         (when (and (name-ref? value) (not (kind? 'NL)))
           (bail 'PARSE-UNEXPECTED-TOKEN
                 (format "expected a newline after the statement; calls need parentheses, as in ~a(...)"
                         (name-ref-name value))
                 (current)))
         (expect 'NL "a newline after the statement")
         (expr-stmt value (span-from start))]))

    (define (parse-binding)
      (define start (expect 'name "a name"))
      (define type
        (if (kind? 'colon)
            (begin (advance!) (parse-type))
            #f))
      (expect 'assign "\"=\"")
      (define value (parse-expression))
      (expect 'NL "a newline after the statement")
      (binding (token-lexeme start) type value (span-from start)))

    (define (parse-compound-assignment)
      (define start (expect 'name "a name"))
      (define operator (advance!))
      (define value (parse-expression))
      (expect 'NL "a newline after the statement")
      (binding (token-lexeme start) #f
               (binary (hash-ref compound-operators (token-kind operator)) (token-span operator)
                       (name-ref (token-lexeme start) (token-span start)) value (span-from start))
               (span-from start)))

    (define (parse-if)
      (define start (current))
      (define first-branch (parse-if-branch))
      (define branches
        (let loop ([acc (list first-branch)])
          (if (kind? 'elsif)
              (loop (cons (parse-if-branch) acc))
              (reverse acc))))
      (define else-body
        (if (kind? 'else)
            (begin
              (advance!)
              (expect 'NL "a newline after else")
              (parse-block))
            #f))
      (expect-end)
      (expect 'NL "a newline after end")
      (if-stmt branches else-body (span-from start)))

    (define (parse-if-branch)
      (define start (advance!))
      (define condition (parse-expression))
      (expect 'NL "a newline after the condition")
      (define body (parse-block))
      (if-branch condition body (span-from start)))

    (define (parse-while)
      (define start (expect 'while "while"))
      (define condition (parse-expression))
      (expect 'NL "a newline after the condition")
      (define body (parse-block))
      (expect-end)
      (expect 'NL "a newline after end")
      (while-stmt condition body (span-from start)))

    (define (parse-for)
      (define start (expect 'for "for"))
      (define variable (expect 'name "a loop variable"))
      (expect 'in "\"in\"")
      (define iterable (parse-expression))
      (expect 'NL "a newline after the loop header")
      (define body (parse-block))
      (expect-end)
      (expect 'NL "a newline after end")
      (for-stmt (token-lexeme variable) iterable body (span-from start)))

    ;; Expressions ---------------------------------------------------------

    (define (parse-expression) (parse-or))

    (define (parse-left-assoc kinds parse-operand)
      (define start (current))
      (let loop ([left (parse-operand)])
        (if (memq (token-kind (current)) kinds)
            (let* ([operator (advance!)]
                   [right (parse-operand)])
              (loop (binary (token-kind operator) (token-span operator) left right (span-from start))))
            left)))

    (define (parse-or) (parse-left-assoc '(or) parse-and))

    (define (parse-and) (parse-left-assoc '(and) parse-equality))

    (define (parse-equality)
      (define start (current))
      (define left (parse-comparison))
      (cond
        [(or (kind? 'equal) (kind? 'not-equal))
         (define operator (advance!))
         (define right (parse-comparison))
         (when (or (kind? 'equal) (kind? 'not-equal))
           (bail 'PARSE-CHAINED-COMPARISON
                 "equality does not chain; combine two comparisons with \"and\""
                 (current)))
         (binary (token-kind operator) (token-span operator) left right (span-from start))]
        [else left]))

    (define (parse-comparison)
      (define start (current))
      (define left (parse-additive))
      (cond
        [(memq (token-kind (current)) '(less less-equal greater greater-equal))
         (define operator (advance!))
         (define right (parse-additive))
         (when (memq (token-kind (current)) '(less less-equal greater greater-equal))
           (bail 'PARSE-CHAINED-COMPARISON
                 "comparison does not chain; write \"a < b and b < c\""
                 (current)))
         (binary (token-kind operator) (token-span operator) left right (span-from start))]
        [else left]))

    (define (parse-additive) (parse-left-assoc '(plus minus) parse-multiplicative))

    (define (parse-multiplicative) (parse-left-assoc '(multiply divide modulo) parse-unary))

    (define (parse-unary)
      (define start (current))
      (cond
        [(kind? 'try)
         (advance!)
         (try-expr (parse-unary) (span-from start))]
        [(or (kind? 'minus) (kind? 'not))
         (define operator (advance!))
         (unary (token-kind operator) (token-span operator) (parse-unary) (span-from start))]
        [else (parse-postfix)]))

    (define (parse-postfix)
      (define start (current))
      (let loop ([target (parse-primary)])
        (cond
          [(kind? 'dot)
           (advance!)
           (define name (expect 'name "a field name"))
           (if (and (equal? (token-lexeme name) "call") (kind? 'left-paren))
               (let ()
                 (advance!)
                 (define arguments (parse-expression-list 'right-paren))
                 (expect 'right-paren "\")\"")
                 (loop (invoke target arguments (span-from start))))
               (loop (field-access target (token-lexeme name) (span-from start))))]
          [(kind? 'left-bracket)
           (advance!)
           (define index (parse-expression))
           (expect 'right-bracket "\"]\"")
           (loop (index-access target index (span-from start)))]
          [else target])))

    (define (parse-primary)
      (define token (current))
      (case (token-kind token)
        [(integer float string) (advance!) (literal (token-value token) (token-span token))]
        [(true) (advance!) (literal #t (token-span token))]
        [(false) (advance!) (literal #f (token-span token))]
        [(nil) (advance!) (literal 'nil (token-span token))]
        [(name) (parse-name-primary)]
        [(ampersand)
         (advance!)
         (define name
           (if (kind? 'type-name)
               (let ([alias (advance!)])
                 (expect 'dot "a dot")
                 (string-append (token-lexeme alias) "."
                                (token-lexeme (expect 'name "a function name" #t))))
               (token-lexeme (expect 'name "a function name" #t))))
         (function-ref name (span-from token))]
        [(type-name) (parse-construct)]
        [(left-paren)
         (advance!)
         (define inner (parse-expression))
         (expect 'right-paren "\")\"")
         inner]
        [(left-bracket) (parse-list-literal)]
        [(left-brace) (parse-map-literal)]
        [else
         (bail 'PARSE-UNEXPECTED-TOKEN
               (format "expected an expression, found ~a" (describe token))
               token)]))

    (define (parse-name-primary)
      (define name (advance!))
      (if (kind? 'left-paren)
          (let ()
            (advance!)
            (define arguments (parse-expression-list 'right-paren))
            (expect 'right-paren "\")\"")
            (call (token-lexeme name) arguments (span-from name)))
          (name-ref (token-lexeme name) (token-span name))))

    (define (parse-construct)
      (define name (current))
      (advance!)
      (cond
        [(kind? 'left-paren)
         (advance!)
         (define arguments (parse-named-arguments))
         (expect 'right-paren "\")\"")
         (construct (token-lexeme name) arguments (span-from name))]
        [(kind? 'dot)
         (advance!)
         (cond
           [(kind? 'type-name)
            (define member (advance!))
            (define qualified (string-append (token-lexeme name) "." (token-lexeme member)))
            (cond
              [(kind? 'dot)
               (advance!)
               (define variant (expect 'type-name "an enum variant"))
               (expect 'left-paren "\"(\"")
               (define arguments (parse-expression-list 'right-paren))
               (expect 'right-paren "\")\"")
               (enum-constructor qualified (token-lexeme variant) arguments (span-from name))]
              [(kind? 'left-paren)
               (advance!)
               (cond
                 [(kind? 'right-paren)
                  (advance!)
                  (construct qualified '() (span-from name))]
                 [(and (kind? 'name) (eq? (token-kind (peek-token 1)) 'colon))
                  (define arguments (parse-named-arguments))
                  (expect 'right-paren "\")\"")
                  (construct qualified arguments (span-from name))]
                 [else
                  (define arguments (parse-expression-list 'right-paren))
                  (expect 'right-paren "\")\"")
                  (enum-constructor (token-lexeme name) (token-lexeme member)
                                    arguments (span-from name))])]
              [else (type-expression qualified (span-from name))])]
           [else
            (define member (expect 'name "a function name" #t))
            (expect 'left-paren "\"(\"")
            (define arguments (parse-expression-list 'right-paren))
            (expect 'right-paren "\")\"")
            (call (string-append (token-lexeme name) "." (token-lexeme member))
                  arguments
                  (span-from name))])]
        [else (type-expression (token-lexeme name) (token-span name))]))

    (define (parse-expression-list terminator)
      (if (kind? terminator)
          '()
          (let loop ([acc (list (parse-expression))])
            (cond
              [(kind? 'comma)
               (advance!)
               (if (kind? terminator)
                   (reverse acc)
                   (loop (cons (parse-expression) acc)))]
              [else (reverse acc)]))))

    (define (parse-named-arguments)
      (if (kind? 'right-paren)
          '()
          (let loop ([acc (list (parse-named-argument))])
            (cond
              [(kind? 'comma)
               (advance!)
               (if (kind? 'right-paren)
                   (reverse acc)
                   (loop (cons (parse-named-argument) acc)))]
              [else (reverse acc)]))))

    (define (parse-named-argument)
      (define start (expect 'name "a field name"))
      (expect 'colon "\":\"")
      (define value (parse-expression))
      (named-arg (token-lexeme start) value (span-from start)))

    (define (parse-list-literal)
      (define start (expect 'left-bracket "\"[\""))
      (define elements (parse-expression-list 'right-bracket))
      (expect 'right-bracket "\"]\"")
      (list-lit elements (span-from start)))

    (define (parse-map-entry)
      (define start (current))
      (define key (parse-expression))
      (expect 'colon "\":\"")
      (map-entry key (parse-expression) (span-from start)))

    (define (parse-map-literal)
      (define start (expect 'left-brace "\"{\""))
      (define entries
        (if (kind? 'right-brace)
            '()
            (let loop ([acc (list (parse-map-entry))])
              (cond
                [(kind? 'comma)
                 (advance!)
                 (if (kind? 'right-brace)
                     (reverse acc)
                     (loop (cons (parse-map-entry) acc)))]
                [else (reverse acc)]))))
      (expect 'right-brace "\"}\"")
      (map-lit entries (span-from start)))

    (parse-program)))
