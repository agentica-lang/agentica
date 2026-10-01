#lang racket

(require "ast.rkt"
         "diagnostic.rkt")

(provide evaluate
         (struct-out instance))

(struct instance (type-name fields) #:transparent)

(define int-min (- (expt 2 63)))
(define int-max (sub1 (expt 2 63)))

(define max-call-depth 10000)

(define (evaluate program)
  (define functions (make-hash))
  (define scopes '())
  (define return-to #f)
  (define depth 0)

  (with-handlers ([exn:fail?
                   (lambda (failure)
                     (diagnostic 'RUNTIME-INTERNAL
                                 (exn-message failure)
                                 (program-span program)))])
   (let/ec escape
    (define (bail code message span)
      (escape (diagnostic code message span)))

    (define (push-scope!) (set! scopes (cons (make-hash) scopes)))
    (define (pop-scope!) (set! scopes (cdr scopes)))

    (define (lookup name)
      (for/or ([frame (in-list scopes)])
        (hash-ref frame name #f)))

    (define (define! name value)
      (hash-set! (car scopes) name (box value)))

    (define (assign! name value)
      (set-box! (lookup name) value))

    (define (in-int-range n span)
      (unless (<= int-min n int-max)
        (bail 'RUNTIME-INTEGER-OVERFLOW "Int result is outside the 64-bit range" span))
      n)

    (define (unreachable what span)
      (bail 'RUNTIME-UNREACHABLE (format "cannot evaluate ~a" what) span))

    ;; Expressions ----------------------------------------------------------

    (define (eval-expression expression)
      (cond
        [(literal? expression) (literal-value expression)]
        [(name-ref? expression) (unbox (lookup (name-ref-name expression)))]
        [(unary? expression) (eval-unary expression)]
        [(binary? expression) (eval-binary expression)]
        [(call? expression) (eval-call expression)]
        [(construct? expression)
         (instance (construct-type-name expression)
                   (for/fold ([fields (hash)])
                             ([argument (in-list (construct-args expression))])
                     (hash-set fields (named-arg-name argument)
                               (eval-expression (named-arg-value argument)))))]
        [(list-lit? expression)
         (for/list ([element (in-list (list-lit-elements expression))])
           (eval-expression element))]
        [(field-access? expression)
         (hash-ref (instance-fields (eval-expression (field-access-target expression)))
                   (field-access-name expression))]
        [(index-access? expression)
         (define target (eval-expression (index-access-target expression)))
         (define index (eval-expression (index-access-index expression)))
         (unless (< -1 index (length target))
           (bail 'RUNTIME-INDEX-OUT-OF-RANGE
                 (format "index ~a is outside a list of length ~a" index (length target))
                 (node-span (index-access-index expression))))
         (list-ref target index)]
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

    (define (eval-call expression)
      (define arguments
        (for/list ([argument (in-list (call-args expression))])
          (eval-expression argument)))
      (define name (call-name expression))
      (if (string=? name "puts")
          (begin (displayln (car arguments)) 'nil)
          (call-function (hash-ref functions name) arguments (call-span expression))))

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
      (when (function-decl? declaration)
        (hash-set! functions (function-decl-name declaration) declaration)))
    (call-function (hash-ref functions "main") '() (program-span program)))))
