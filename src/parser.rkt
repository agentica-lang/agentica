#lang racket

(require "ast.rkt"
         "diagnostic.rkt"
         "source.rkt"
         "token.rkt")

(provide parse)

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
            [(kind? 'def) (loop (cons (parse-function-decl) acc))]
            [(kind? 'struct) (loop (cons (parse-struct-decl) acc))]
            [else
             (bail 'PARSE-TOP-LEVEL-STATEMENT
                   (format "expected a top-level declaration (def or struct), found ~a"
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
      (type-ref (token-lexeme start) arguments (span-from start)))

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

    ;; Statements ----------------------------------------------------------

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
        [else
         (define start (current))
         (define value (parse-expression))
         (when (kind? 'assign)
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
           (loop (field-access target (token-lexeme name) (span-from start)))]
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
         (define member (expect 'name "a function name" #t))
         (expect 'left-paren "\"(\"")
         (define arguments (parse-expression-list 'right-paren))
         (expect 'right-paren "\")\"")
         (call (string-append (token-lexeme name) "." (token-lexeme member))
               arguments
               (span-from name))]
        [else
         (bail 'PARSE-UNEXPECTED-TOKEN
               "a type name is only a type or a constructor call; add \"(\""
               name)]))

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
