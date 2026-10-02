#lang racket

(require "builtins.rkt"
         "ast.rkt"
         "diagnostic.rkt")

(provide evaluate
         (struct-out instance)
         (struct-out mapping)
         (struct-out exit-code))

(struct instance (type-name fields) #:transparent)
(struct mapping (pairs) #:transparent)
(struct exit-code (code) #:transparent)
(struct result-ok (value) #:transparent)
(struct result-error (message) #:transparent)

(define (mapping-put target key value)
  (define pairs (mapping-pairs target))
  (mapping
   (if (assoc key pairs)
       (for/list ([pair (in-list pairs)])
         (if (equal? (car pair) key) (cons key value) pair))
       (append pairs (list (cons key value))))))

(define int-min (- (expt 2 63)))
(define int-max (sub1 (expt 2 63)))
(define decimal-integer-pattern #px"^[+-]?[0-9]+$")
(define decimal-float-pattern #px"^[+-]?[0-9]+(\\.[0-9]+)?$")

(define max-call-depth 10000)

(define (evaluate program
                  #:in [input (current-input-port)]
                  #:out [output (current-output-port)]
                  #:err [error-output (current-error-port)]
                  #:args [program-args '()]
                  #:max-steps [max-steps #f])
  (parameterize ([current-input-port input]
                 [current-output-port output]
                 [current-error-port error-output])
    (evaluate-with-ports program program-args max-steps)))

(define (evaluate-with-ports program program-args max-steps)
  (define functions (make-hash))
  (define struct-fields (make-hash))
  (define scopes '())
  (define return-to #f)
  (define depth 0)
  (define steps 0)

  (with-handlers ([exn:fail?
                   (lambda (failure)
                     (diagnostic 'RUNTIME-INTERNAL
                                 (exn-message failure)
                                 (program-span program)))])
   (let/ec escape
    (define (bail code message span)
      (escape (diagnostic code message span)))

    (unless (or (not max-steps) (exact-positive-integer? max-steps))
      (bail 'RUNTIME-INTERNAL "max-steps must be a positive integer or #f" (program-span program)))

    (define (step! span)
      (when max-steps
        (when (>= steps max-steps)
          (bail 'RUNTIME-STEP-LIMIT "execution step budget exhausted" span))
        (set! steps (add1 steps))))

    (define (push-scope!) (set! scopes (cons (make-hash) scopes)))
    (define (pop-scope!) (set! scopes (cdr scopes)))

    (define (lookup name)
      (for/or ([frame (in-list scopes)])
        (hash-ref frame name #f)))

    (define (define! name value)
      (hash-set! (car scopes) name (box value)))

    (define (assign! name value)
      (set-box! (lookup name) value))

    (define (in-int-range n span [fail bail])
      (unless (<= int-min n int-max)
        (fail 'RUNTIME-INTEGER-OVERFLOW "Int result is outside the 64-bit range" span))
      n)

    (define (unreachable what span)
      (bail 'RUNTIME-UNREACHABLE (format "cannot evaluate ~a" what) span))

    (define (fallible bang? operation)
      (let/ec failed
        (define (fail code message where)
          (if bang? (bail code message where) (failed (result-error message))))
        (define value (operation fail))
        (if bang? value (result-ok value))))

    ;; Expressions ----------------------------------------------------------

    (define (eval-expression expression)
      (step! (node-span expression))
      (cond
        [(literal? expression) (literal-value expression)]
        [(name-ref? expression) (unbox (lookup (name-ref-name expression)))]
        [(unary? expression) (eval-unary expression)]
        [(binary? expression) (eval-binary expression)]
        [(call? expression) (eval-call expression)]
        [(try-expr? expression)
         (define result (eval-expression (try-expr-operand expression)))
         (if (result-ok? result) (result-ok-value result) (return-to result))]
        [(construct? expression)
         (instance (construct-type-name expression)
                   (for/fold ([fields (hash)])
                             ([argument (in-list (construct-args expression))])
                     (hash-set fields (named-arg-name argument)
                               (eval-expression (named-arg-value argument)))))]
        [(list-lit? expression)
         (for/list ([element (in-list (list-lit-elements expression))])
           (eval-expression element))]
        [(map-lit? expression)
         (for/fold ([result (mapping '())])
                   ([entry (in-list (map-lit-entries expression))])
           (mapping-put result
                        (eval-expression (map-entry-key entry))
                        (eval-expression (map-entry-value entry))))]
        [(field-access? expression)
         (hash-ref (instance-fields (eval-expression (field-access-target expression)))
                   (field-access-name expression))]
        [(index-access? expression)
         (define target (eval-expression (index-access-target expression)))
         (define index (eval-expression (index-access-index expression)))
         (cond
           [(mapping? target)
            (define pair (assoc index (mapping-pairs target)))
            (unless pair
              (bail 'RUNTIME-KEY-NOT-FOUND
                    (format "key ~s is not in the map" index)
                    (node-span (index-access-index expression))))
            (cdr pair)]
           [else
            (unless (< -1 index (length target))
              (bail 'RUNTIME-INDEX-OUT-OF-RANGE
                    (format "index ~a is outside a list of length ~a" index (length target))
                    (node-span (index-access-index expression))))
            (list-ref target index)])]
        [else (unreachable "expression" (node-span expression))]))

    (define (eval-unary expression)
      (define operand (eval-expression (unary-operand expression)))
      (case (unary-op expression)
        [(minus) (if (exact-integer? operand)
                     (in-int-range (- operand) (unary-op-span expression))
                     (- operand))]
        [(not) (not operand)]
        [else (unreachable "unary operator" (unary-op-span expression))]))

    (define (eval-binary expression)
      (define op (binary-op expression))
      (define span (binary-op-span expression))
      (define left (eval-expression (binary-left expression)))
      (case op
        [(and) (and left (eval-expression (binary-right expression)))]
        [(or) (or left (eval-expression (binary-right expression)))]
        [else
         (define right (eval-expression (binary-right expression)))
         (define ints? (exact-integer? left))
         (define (checked n) (if ints? (in-int-range n span) n))
         (define (non-zero!)
           (when (zero? right)
             (bail 'RUNTIME-DIVISION-BY-ZERO "division by zero" span)))
         (case op
           [(plus) (if (string? left) (string-append left right) (checked (+ left right)))]
           [(minus) (checked (- left right))]
           [(multiply) (checked (* left right))]
           [(divide)
            (non-zero!)
            (if ints? (checked (quotient left right)) (/ left right))]
           [(modulo) (non-zero!) (remainder left right)]
           [(less) (< left right)]
           [(less-equal) (<= left right)]
           [(greater) (> left right)]
           [(greater-equal) (>= left right)]
           [(equal) (if (number? left) (= left right) (equal? left right))]
           [(not-equal) (not (if (number? left) (= left right) (equal? left right)))]
           [else (unreachable "operator" span)])]))

    (define (value->debug-string value)
      (cond
        [(eq? value 'nil) "nil"]
        [(boolean? value) (if value "true" "false")]
        [(string? value) (format "~s" value)]
        [(number? value) (number->string value)]
        [(result-ok? value) (format "ok(~a)" (value->debug-string (result-ok-value value)))]
        [(result-error? value) (format "error(~s)" (result-error-message value))]
        [(instance? value)
         (define field-order (hash-ref struct-fields (instance-type-name value) '()))
         (format "~a(~a)"
                 (instance-type-name value)
                 (string-join
                  (for/list ([field (in-list field-order)])
                    (format "~a: ~a" field
                            (value->debug-string
                             (hash-ref (instance-fields value) field))))
                  ", "))]
        [(mapping? value)
         (format "{~a}"
                 (string-join
                  (for/list ([pair (in-list (mapping-pairs value))])
                    (format "~a: ~a"
                            (value->debug-string (car pair))
                            (value->debug-string (cdr pair))))
                  ", "))]
        [(list? value)
         (format "[~a]" (string-join (map value->debug-string value) ", "))]
        [else (format "~s" value)]))

    (define (eval-call expression)
      (define arguments
        (for/list ([argument (in-list (call-args expression))])
          (eval-expression argument)))
      (define entry (builtin-ref (call-name expression)))
      (define name (if entry (builtin-implementation entry) (call-name expression)))
      (define span (call-span expression))
      (case name
        [("puts") (displayln (car arguments)) 'nil]
        [("ok") (result-ok (car arguments))]
        [("error") (result-error (car arguments))]
        [("Result.ok?") (result-ok? (car arguments))]
        [("Result.message")
         (if (result-error? (car arguments)) (result-error-message (car arguments)) "")]
        [("Result.unwrap!")
         (define result (car arguments))
         (if (result-ok? result)
             (result-ok-value result)
             (bail 'RUNTIME-UNWRAP-ERROR (result-error-message result) span))]
        [("Result.unwrap_or")
         (if (result-ok? (car arguments)) (result-ok-value (car arguments)) (cadr arguments))]
        [("IO.print") (display (car arguments)) 'nil]
        [("IO.warn") (displayln (car arguments) (current-error-port)) 'nil]
        [("IO.inspect")
         (displayln (value->debug-string (car arguments)))
         (car arguments)]
        [("IO.gets" "IO.gets!")
         (fallible (string-suffix? name "!")
                   (lambda (fail)
                     (define line (read-line (current-input-port) 'any))
                     (when (eof-object? line)
                       (fail 'RUNTIME-END-OF-INPUT "IO.gets reached the end of input" span))
                     line))]
        [("IO.read") (port->string (current-input-port))]
        [("IO.eof?") (eof-object? (peek-char (current-input-port)))]
        [("System.args") program-args]
        [("System.exit") (escape (exit-code (car arguments)))]
        [("Map.has_key?") (and (assoc (cadr arguments) (mapping-pairs (car arguments))) #t)]
        [("Map.keys") (map car (mapping-pairs (car arguments)))]
        [("Map.size") (length (mapping-pairs (car arguments)))]
        [("Map.put") (mapping-put (car arguments) (cadr arguments) (caddr arguments))]
        [("List.size") (length (car arguments))]
        [("String.length") (string-length (car arguments))]
        [("String.upcase") (string-upcase (car arguments))]
        [("String.downcase") (string-downcase (car arguments))]
        [("String.trim") (string-trim (car arguments))]
        [("String.split")
         (define text (car arguments))
         (define separator (cadr arguments))
         (if (string=? separator "")
             (map string (string->list text))
             (string-split text separator))]
        [("String.join") (string-join (car arguments) (cadr arguments))]
        [("String.contains?") (string-contains? (car arguments) (cadr arguments))]
        [("String.starts_with?") (string-prefix? (car arguments) (cadr arguments))]
        [("String.ends_with?") (string-suffix? (car arguments) (cadr arguments))]
        [("String.replace") (string-replace (car arguments) (cadr arguments) (caddr arguments))]
        [("String.slice")
         (define text (car arguments))
         (define start (cadr arguments))
         (define length (caddr arguments))
         (unless (and (>= start 0)
                      (>= length 0)
                      (<= (+ start length) (string-length text)))
           (bail 'RUNTIME-INDEX-OUT-OF-RANGE
                 (format "slice ~a,~a is outside a string of length ~a"
                         start length (string-length text))
                 (call-span expression)))
         (substring text start (+ start length))]
        [("String.from_int") (number->string (car arguments))]
        [("String.from_float") (number->string (car arguments))]
        [("String.to_int" "String.to_int!")
         (fallible (string-suffix? name "!")
                   (lambda (fail)
                     (define text (car arguments))
                     (define parsed-int
                       (and (regexp-match? decimal-integer-pattern text) (string->number text)))
                     (unless (exact-integer? parsed-int)
                       (fail 'RUNTIME-INVALID-NUMBER (format "cannot convert ~s to Int" text) span))
                     (in-int-range parsed-int span fail)))]
        [("String.to_float" "String.to_float!")
         (fallible (string-suffix? name "!")
                   (lambda (fail)
                     (define text (car arguments))
                     (define parsed-float
                       (and (regexp-match? decimal-float-pattern text) (string->number text)))
                     (unless (real? parsed-float)
                       (fail 'RUNTIME-INVALID-NUMBER (format "cannot convert ~s to Float" text) span))
                     (exact->inexact parsed-float)))]
        [else
         (when entry (unreachable "builtin implementation" span))
         (define declaration (hash-ref functions name #f))
         (unless declaration (unreachable "call" (call-span expression)))
         (call-function declaration arguments (call-span expression))]))

    (define (call-function declaration arguments span)
      (when (>= depth max-call-depth)
        (bail 'RUNTIME-STACK-OVERFLOW "call depth limit exceeded" span))
      (define saved-scopes scopes)
      (define saved-return return-to)
      (set! depth (add1 depth))
      (define result
        (let/ec done
          (set! return-to done)
          (set! scopes '())
          (push-scope!)
          (for ([parameter (in-list (function-decl-params declaration))]
                [argument (in-list arguments)])
            (define! (param-name parameter) argument))
          (exec-block (function-decl-body declaration))
          'nil))
      (set! depth (sub1 depth))
      (set! scopes saved-scopes)
      (set! return-to saved-return)
      result)

    ;; Statements -----------------------------------------------------------

    (define (exec-block statements)
      (for ([statement (in-list statements)])
        (exec-statement statement)))

    (define (exec-scoped statements)
      (push-scope!)
      (exec-block statements)
      (pop-scope!))

    (define (exec-statement statement)
      (step! (node-span statement))
      (cond
        [(binding? statement)
         (define value (eval-expression (binding-value statement)))
         (if (and (not (binding-type statement)) (lookup (binding-name statement)))
             (assign! (binding-name statement) value)
             (define! (binding-name statement) value))]
        [(return-stmt? statement)
         (return-to (if (return-stmt-value statement)
                        (eval-expression (return-stmt-value statement))
                        'nil))]
        [(expr-stmt? statement) (eval-expression (expr-stmt-value statement))]
        [(if-stmt? statement)
         (define branch
           (for/first ([branch (in-list (if-stmt-branches statement))]
                       #:when (eval-expression (if-branch-condition branch)))
             branch))
         (cond
           [branch (exec-scoped (if-branch-body branch))]
           [(if-stmt-else-body statement) (exec-scoped (if-stmt-else-body statement))])]
        [(while-stmt? statement)
         (let loop ()
           (when (eval-expression (while-stmt-condition statement))
             (exec-scoped (while-stmt-body statement))
             (loop)))]
        [(for-stmt? statement)
         (for ([element (in-list (eval-expression (for-stmt-iterable statement)))])
           (push-scope!)
           (define! (for-stmt-var statement) element)
           (exec-block (for-stmt-body statement))
           (pop-scope!))]
        [else (unreachable "statement" (node-span statement))]))

    ;; Program --------------------------------------------------------------

    (for ([declaration (in-list (program-declarations program))])
      (cond
        [(function-decl? declaration)
         (hash-set! functions (function-decl-name declaration) declaration)]
        [(struct-decl? declaration)
         (hash-set! struct-fields (struct-decl-name declaration)
                    (map field-decl-name (struct-decl-fields declaration)))]))
    (call-function (hash-ref functions "main") '() (program-span program)))))
