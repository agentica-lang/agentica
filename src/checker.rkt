#lang racket

(require "ast.rkt"
         "diagnostic.rkt"
         "source.rkt")

(provide check)

(define int-max (sub1 (expt 2 63)))

(define reserved-type-names '("Int" "Float" "Bool" "String" "Nil" "List"))

(define (type->string type)
  (cond
    [(symbol? type) (symbol->string type)]
    [(eq? (car type) 'List) (format "List[~a]" (type->string (cadr type)))]
    [(eq? (car type) 'Struct) (cadr type)]
    [else "?"]))

(define (numeric-type? type)
  (or (eq? type 'Int) (eq? type 'Float)))

(define (primitive-type? type)
  (memq type '(Int Float Bool String Nil)))

(define (list-type? type)
  (and (pair? type) (eq? (car type) 'List)))

(define (struct-type? type)
  (and (pair? type) (eq? (car type) 'Struct)))

(define (literal-type value)
  (cond
    [(boolean? value) 'Bool]
    [(exact-integer? value) 'Int]
    [(flonum? value) 'Float]
    [(string? value) 'String]
    [(eq? value 'nil) 'Nil]
    [else '?]))

(define (block-returns? statements)
  (ormap returns? statements))

(define (returns? statement)
  (cond
    [(return-stmt? statement) #t]
    [(if-stmt? statement)
     (and (if-stmt-else-body statement)
          (for/and ([branch (in-list (if-stmt-branches statement))])
            (block-returns? (if-branch-body branch)))
          (block-returns? (if-stmt-else-body statement)))]
    [else #f]))

(define (check program)
  (define structs (make-hash))
  (define functions (make-hash))
  (define scopes '())
  (define current-result 'Nil)

  (let/ec return
    (define (bail code message span)
      (return (diagnostic code message span)))

    (define (mismatch! expected actual span)
      (bail 'CHECK-TYPE-MISMATCH
            (format "expected ~a, found ~a" (type->string expected) (type->string actual))
            span))

    (define (ensure actual expected span)
      (when (and expected (not (equal? actual expected)))
        (mismatch! expected actual span))
      actual)

    (define (resolve-type reference)
      (define name (type-ref-name reference))
      (define arguments (type-ref-args reference))
      (cond
        [(and (member name '("Int" "Float" "Bool" "String" "Nil"))
              (null? arguments))
         (string->symbol name)]
        [(and (string=? name "List") (= (length arguments) 1))
         (list 'List (resolve-type (car arguments)))]
        [(and (hash-has-key? structs name) (null? arguments))
         (list 'Struct name)]
        [else
         (bail 'CHECK-UNKNOWN-TYPE
               (format "unknown type \"~a\"" name)
               (type-ref-span reference))]))

    ;; Scopes ---------------------------------------------------------------

    (define (push-scope!) (set! scopes (cons (make-hash) scopes)))
    (define (pop-scope!) (set! scopes (cdr scopes)))

    (define (lookup name)
      (let loop ([frames scopes])
        (cond
          [(null? frames) #f]
          [(hash-ref (car frames) name #f) => values]
          [else (loop (cdr frames))])))

    (define (introduce! name type span [immutable? #f])
      (when (lookup name)
        (bail 'CHECK-SHADOWED-NAME
              (format "\"~a\" is already visible; Agentica does not allow shadowing" name)
              span))
      (hash-set! (car scopes) name (cons type immutable?)))

    ;; Registration ---------------------------------------------------------

    (define (register-structs!)
      (for ([declaration (in-list (program-declarations program))])
        (when (struct-decl? declaration)
          (define name (struct-decl-name declaration))
          (when (or (member name reserved-type-names)
                    (hash-has-key? structs name)
                    (hash-has-key? functions name))
            (bail 'CHECK-REDEFINED-NAME
                  (format "\"~a\" is already defined" name)
                  (struct-decl-span declaration)))
          (hash-set! structs name '())))
      (for ([declaration (in-list (program-declarations program))])
        (when (struct-decl? declaration)
          (define seen '())
          (hash-set! structs (struct-decl-name declaration)
                     (for/list ([field (in-list (struct-decl-fields declaration))])
                       (define field-name (field-decl-name field))
                       (when (member field-name seen)
                         (bail 'CHECK-REDEFINED-NAME
                               (format "duplicate field \"~a\"" field-name)
                               (field-decl-span field)))
                       (set! seen (cons field-name seen))
                       (cons field-name (resolve-type (field-decl-type field))))))))

    (define (register-functions!)
      (for ([declaration (in-list (program-declarations program))])
        (when (function-decl? declaration)
          (define name (function-decl-name declaration))
          (when (or (hash-has-key? functions name)
                    (hash-has-key? structs name))
            (bail 'CHECK-REDEFINED-NAME
                  (format "\"~a\" is already defined" name)
                  (function-decl-span declaration)))
          (define seen '())
          (define parameter-types
            (for/list ([parameter (in-list (function-decl-params declaration))])
              (when (member (param-name parameter) seen)
                (bail 'CHECK-REDEFINED-NAME
                      (format "duplicate parameter \"~a\"" (param-name parameter))
                      (param-span parameter)))
              (set! seen (cons (param-name parameter) seen))
              (resolve-type (param-type parameter))))
          (hash-set! functions name
                     (list parameter-types (resolve-type (function-decl-result declaration)))))))

    (define (check-main!)
      (define mains
        (for/list ([declaration (in-list (program-declarations program))]
                   #:when (and (function-decl? declaration)
                               (string=? (function-decl-name declaration) "main")))
          declaration))
      (cond
        [(null? mains)
         (bail 'CHECK-MAIN "a program must declare exactly one main() -> Nil" (program-span program))]
        [else
         (define main (car mains))
         (unless (and (null? (function-decl-params main))
                      (eq? (resolve-type (function-decl-result main)) 'Nil))
           (bail 'CHECK-MAIN "main must take no parameters and return Nil"
                 (function-decl-span main)))]))

    ;; Expressions ----------------------------------------------------------

    (define (check-expression expression expected)
      (define actual
        (cond
          [(literal? expression)
           (when (and (exact-integer? (literal-value expression))
                      (> (literal-value expression) int-max))
             (bail 'CHECK-INT-RANGE
                   "Int literal is outside the signed 64-bit range"
                   (literal-span expression)))
           (literal-type (literal-value expression))]
          [(name-ref? expression)
           (define binding (lookup (name-ref-name expression)))
           (unless binding
             (bail 'CHECK-UNKNOWN-NAME
                   (if (hash-has-key? functions (name-ref-name expression))
                       (format "\"~a\" is a function; functions are not values"
                               (name-ref-name expression))
                       (format "unknown name \"~a\"" (name-ref-name expression)))
                   (name-ref-span expression)))
           (car binding)]
          [(unary? expression) (check-unary expression)]
          [(binary? expression) (check-binary expression)]
          [(call? expression) (check-call expression)]
          [(construct? expression) (check-construct expression)]
          [(list-lit? expression) (check-list expression expected)]
          [(field-access? expression) (check-field-access expression)]
          [(index-access? expression) (check-index-access expression)]
          [else (bail 'CHECK-INTERNAL "unsupported expression" (node-span expression))]))
      (ensure actual expected (node-span expression)))

    (define (check-unary expression)
      (define inner (unary-operand expression))
      (define operand
        (if (and (eq? (unary-op expression) 'minus)
                 (literal? inner)
                 (eqv? (literal-value inner) (add1 int-max)))
            'Int
            (check-expression inner #f)))
      (case (unary-op expression)
        [(minus)
         (unless (numeric-type? operand)
           (bail 'CHECK-TYPE-MISMATCH
                 (format "unary \"-\" expects a number, found ~a" (type->string operand))
                 (unary-op-span expression)))
         operand]
        [(not)
         (unless (eq? operand 'Bool)
           (bail 'CHECK-TYPE-MISMATCH
                 (format "\"not\" expects Bool, found ~a" (type->string operand))
                 (unary-op-span expression)))
         'Bool]
        [else (bail 'CHECK-INTERNAL "unsupported unary operator" (unary-op-span expression))]))

    (define (check-binary expression)
      (define left (check-expression (binary-left expression) #f))
      (define right (check-expression (binary-right expression) #f))
      (define span (binary-op-span expression))
      (define (same!)
        (unless (equal? left right)
          (bail 'CHECK-TYPE-MISMATCH
                (format "operator expects two values of the same type, found ~a and ~a"
                        (type->string left) (type->string right))
                span)))
      (case (binary-op expression)
        [(plus)
         (same!)
         (cond
           [(and (numeric-type? left) (numeric-type? right)) left]
           [(and (eq? left 'String) (eq? right 'String)) 'String]
           [else
            (bail 'CHECK-TYPE-MISMATCH
                  (format "\"+\" expects two numbers or two strings, found ~a" (type->string left))
                  span)])]
        [(minus multiply divide)
         (same!)
         (unless (and (numeric-type? left) (numeric-type? right))
           (bail 'CHECK-TYPE-MISMATCH
                 (format "arithmetic expects two numbers, found ~a" (type->string left))
                 span))
         left]
        [(modulo)
         (unless (and (eq? left 'Int) (eq? right 'Int))
           (bail 'CHECK-TYPE-MISMATCH
                 (format "\"%%\" expects two Ints, found ~a and ~a"
                         (type->string left) (type->string right))
                 span))
         'Int]
        [(less less-equal greater greater-equal)
         (same!)
         (unless (and (numeric-type? left) (numeric-type? right))
           (bail 'CHECK-TYPE-MISMATCH
                 (format "comparison expects two numbers, found ~a" (type->string left))
                 span))
         'Bool]
        [(equal not-equal)
         (same!)
         (unless (primitive-type? left)
           (bail 'CHECK-TYPE-MISMATCH
                 (format "equality is only defined for primitive values, found ~a"
                         (type->string left))
                 span))
         'Bool]
        [(and or)
         (unless (and (eq? left 'Bool) (eq? right 'Bool))
           (bail 'CHECK-TYPE-MISMATCH
                 (format "logical operator expects two Bools, found ~a and ~a"
                         (type->string left) (type->string right))
                 span))
         'Bool]
        [else (bail 'CHECK-INTERNAL "unsupported operator" span)]))

    (define (check-call expression)
      (define name (call-name expression))
      (define entry (hash-ref functions name #f))
      (unless entry
        (bail 'CHECK-UNKNOWN-NAME
              (format "unknown function \"~a\"" name)
              (call-span expression)))
      (define parameter-types (car entry))
      (define result-type (cadr entry))
      (define arguments (call-args expression))
      (unless (= (length arguments) (length parameter-types))
        (bail 'CHECK-ARITY
              (format "\"~a\" expects ~a argument(s), found ~a"
                      name (length parameter-types) (length arguments))
              (call-span expression)))
      (for ([argument (in-list arguments)]
            [parameter-type (in-list parameter-types)])
        (check-expression argument parameter-type))
      result-type)

    (define (check-construct expression)
      (define name (construct-type-name expression))
      (unless (hash-has-key? structs name)
        (bail 'CHECK-UNKNOWN-TYPE
              (format "\"~a\" is not a declared struct" name)
              (construct-span expression)))
      (define fields (hash-ref structs name))
      (define seen '())
      (for ([argument (in-list (construct-args expression))])
        (define field-name (named-arg-name argument))
        (define field (assoc field-name fields))
        (unless field
          (bail 'CHECK-UNKNOWN-FIELD
                (format "\"~a\" has no field \"~a\"" name field-name)
                (named-arg-span argument)))
        (when (member field-name seen)
          (bail 'CHECK-DUPLICATE-FIELD
                (format "field \"~a\" is given twice" field-name)
                (named-arg-span argument)))
        (set! seen (cons field-name seen))
        (check-expression (named-arg-value argument) (cdr field)))
      (for ([field (in-list fields)])
        (unless (member (car field) seen)
          (bail 'CHECK-MISSING-FIELD
                (format "constructor \"~a\" is missing field \"~a\"" name (car field))
                (construct-span expression))))
      (list 'Struct name))

    (define (check-list expression expected)
      (define span (list-lit-span expression))
      (define elements (list-lit-elements expression))
      (when (and expected (not (list-type? expected)))
        (bail 'CHECK-TYPE-MISMATCH
              (format "expected ~a, found a list" (type->string expected))
              span))
      (define expected-element (and expected (list-type? expected) (cadr expected)))
      (cond
        [(null? elements)
         (unless expected-element
           (bail 'CHECK-EMPTY-LIST-TYPE
                 "an empty list needs an expected type, for example \"List[Int]\""
                 span))
         expected]
        [else
         (define first-type (check-expression (car elements) expected-element))
         (define element-type (or expected-element first-type))
         (for ([element (in-list (cdr elements))])
           (check-expression element element-type))
         (list 'List element-type)]))

    (define (check-field-access expression)
      (define target (check-expression (field-access-target expression) #f))
      (unless (struct-type? target)
        (bail 'CHECK-NOT-A-STRUCT
              (format "field access needs a struct, found ~a" (type->string target))
              (field-access-span expression)))
      (define field (assoc (field-access-name expression) (hash-ref structs (cadr target))))
      (unless field
        (bail 'CHECK-UNKNOWN-FIELD
              (format "\"~a\" has no field \"~a\"" (cadr target) (field-access-name expression))
              (field-access-span expression)))
      (cdr field))

    (define (check-index-access expression)
      (define target (check-expression (index-access-target expression) #f))
      (unless (list-type? target)
        (bail 'CHECK-NOT-A-LIST
              (format "indexing needs a list, found ~a" (type->string target))
              (index-access-span expression)))
      (check-expression (index-access-index expression) 'Int)
      (cadr target))

    ;; Statements -----------------------------------------------------------

    (define (check-block statements)
      (for ([statement (in-list statements)])
        (check-statement statement)))

    (define (check-statement statement)
      (cond
        [(binding? statement) (check-binding statement)]
        [(return-stmt? statement) (check-return statement)]
        [(expr-stmt? statement) (check-expression (expr-stmt-value statement) #f)]
        [(if-stmt? statement) (check-if statement)]
        [(while-stmt? statement) (check-while statement)]
        [(for-stmt? statement) (check-for statement)]
        [else (bail 'CHECK-INTERNAL "unsupported statement" (node-span statement))]))

    (define (check-binding statement)
      (define name (binding-name statement))
      (define annotation (binding-type statement))
      (define declared (and annotation (resolve-type annotation)))
      (define existing (lookup name))
      (cond
        [existing
         (when annotation
           (bail 'CHECK-ANNOTATION-ON-EXISTING
                 (format "an annotation is only allowed when \"~a\" is introduced" name)
                 (binding-span statement)))
         (when (cdr existing)
           (bail 'CHECK-IMMUTABLE-ASSIGNMENT
                 (format "\"~a\" cannot be assigned" name)
                 (binding-span statement)))
         (check-expression (binding-value statement) (car existing))]
        [else
         (define value-type (check-expression (binding-value statement) declared))
         (introduce! name (or declared value-type) (binding-span statement))]))

    (define (check-return statement)
      (define value (return-stmt-value statement))
      (if value
          (check-expression value current-result)
          (ensure 'Nil current-result (return-stmt-span statement))))

    (define (check-if statement)
      (for ([branch (in-list (if-stmt-branches statement))])
        (check-expression (if-branch-condition branch) 'Bool)
        (push-scope!)
        (check-block (if-branch-body branch))
        (pop-scope!))
      (define else-body (if-stmt-else-body statement))
      (when else-body
        (push-scope!)
        (check-block else-body)
        (pop-scope!)))

    (define (check-while statement)
      (check-expression (while-stmt-condition statement) 'Bool)
      (push-scope!)
      (check-block (while-stmt-body statement))
      (pop-scope!))

    (define (check-for statement)
      (define iterable (check-expression (for-stmt-iterable statement) #f))
      (unless (list-type? iterable)
        (bail 'CHECK-NOT-A-LIST
              (format "\"for\" iterates over a list, found ~a" (type->string iterable))
              (for-stmt-span statement)))
      (push-scope!)
      (introduce! (for-stmt-var statement) (cadr iterable) (for-stmt-span statement) #t)
      (check-block (for-stmt-body statement))
      (pop-scope!))

    (define (check-function declaration)
      (define result-type (resolve-type (function-decl-result declaration)))
      (set! current-result result-type)
      (push-scope!)
      (for ([parameter (in-list (function-decl-params declaration))])
        (introduce! (param-name parameter) (resolve-type (param-type parameter)) (param-span parameter)))
      (check-block (function-decl-body declaration))
      (pop-scope!)
      (when (and (not (eq? result-type 'Nil))
                 (not (block-returns? (function-decl-body declaration))))
        (bail 'CHECK-MISSING-RETURN
              (format "function \"~a\" must return ~a on every path"
                      (function-decl-name declaration) (type->string result-type))
              (function-decl-span declaration))))

    ;; Program --------------------------------------------------------------

    (hash-set! functions "puts" (list (list 'String) 'Nil))
    (register-structs!)
    (register-functions!)
    (check-main!)
    (for ([declaration (in-list (program-declarations program))])
      (when (function-decl? declaration)
        (check-function declaration)))
    program))
