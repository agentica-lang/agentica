#lang racket

(require "ast.rkt"
         "diagnostic.rkt"
         "source.rkt")

(provide check)

(define int-max (sub1 (expt 2 63)))

(define reserved-type-names '("Int" "Float" "Bool" "String" "Nil" "List" "Map" "IO" "System"))

(define (type->string type)
  (cond
    [(symbol? type) (symbol->string type)]
    [(eq? (car type) 'List) (format "List[~a]" (type->string (cadr type)))]
    [(eq? (car type) 'Map)
     (format "Map[~a, ~a]" (type->string (cadr type)) (type->string (caddr type)))]
    [(eq? (car type) 'Struct) (cadr type)]
    [else "?"]))

(define (numeric-type? type)
  (or (eq? type 'Int) (eq? type 'Float)))

(define (primitive-type? type)
  (memq type '(Int Float Bool String Nil)))

(define (list-type? type)
  (and (pair? type) (eq? (car type) 'List)))

(define (map-type? type)
  (and (pair? type) (eq? (car type) 'Map)))

(define (key-type? type)
  (memq type '(Int String)))

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

(define (edit-distance a b)
  (define n (string-length b))
  (define last-row (build-vector (add1 n) values))
  (for ([i (in-range 1 (add1 (string-length a)))])
    (define row (make-vector (add1 n) i))
    (for ([j (in-range 1 (add1 n))])
      (vector-set! row j
                   (min (add1 (vector-ref last-row j))
                        (add1 (vector-ref row (sub1 j)))
                        (+ (vector-ref last-row (sub1 j))
                           (if (char=? (string-ref a (sub1 i)) (string-ref b (sub1 j))) 0 1)))))
    (vector-copy! last-row 0 row))
  (vector-ref last-row n))

(define (did-you-mean name candidates)
  (define limit (if (<= (string-length name) 4) 1 2))
  (define near
    (sort (for/list ([candidate (in-list (remove-duplicates candidates))]
                     #:unless (string=? candidate name)
                     #:when (<= (edit-distance name candidate) limit))
            candidate)
          (lambda (x y)
            (define dx (edit-distance name x))
            (define dy (edit-distance name y))
            (or (< dx dy) (and (= dx dy) (string<? x y))))))
  (and (pair? near) (format "did you mean \"~a\"?" (car near))))

(define (conversion-help expected actual)
  (cond
    [(and (eq? expected 'String) (eq? actual 'Int)) "convert it with String.from_int(...)"]
    [(and (eq? expected 'String) (eq? actual 'Float)) "convert it with String.from_float(...)"]
    [(and (eq? expected 'Int) (eq? actual 'String)) "convert it with String.to_int!(...)"]
    [(and (eq? expected 'Float) (eq? actual 'String)) "convert it with String.to_float!(...)"]
    [else #f]))

(define (contains-return? statements)
  (for/or ([statement (in-list statements)])
    (cond
      [(return-stmt? statement) #t]
      [(if-stmt? statement)
       (or (for/or ([branch (in-list (if-stmt-branches statement))])
             (contains-return? (if-branch-body branch)))
           (and (if-stmt-else-body statement) (contains-return? (if-stmt-else-body statement))))]
      [(while-stmt? statement) (contains-return? (while-stmt-body statement))]
      [(for-stmt? statement) (contains-return? (for-stmt-body statement))]
      [else #f])))

(define (missing-return-help body type-name)
  (cond
    [(not (contains-return? body))
     (format "add \"return <value>\" of type ~a at the end" type-name)]
    [(and (pair? body) (if-stmt? (last body)) (not (if-stmt-else-body (last body))))
     (format "the last \"if\" has no \"else\"; add an \"else\" that returns ~a, or return after it" type-name)]
    [else #f]))

(define (field-help name fields)
  (define names (map car fields))
  (define guess (did-you-mean name names))
  (define all (format "fields: ~a" (string-join names ", ")))
  (if guess (string-append guess " " all) all))

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
  (define current-signature #f)

  (let/ec return
    (define (bail code message span
                  #:expected [expected #f] #:actual [actual #f] #:callee [callee #f]
                  #:labels [labels '()] #:help [help #f])
      (return (diagnostic code message span
                          #:expected expected #:actual actual #:callee callee
                          #:signature current-signature
                          #:labels labels #:help help)))

    (define (mismatch! expected actual span)
      (bail 'CHECK-TYPE-MISMATCH
            (format "expected ~a, found ~a" (type->string expected) (type->string actual))
            span
            #:expected (type->string expected)
            #:actual (type->string actual)
            #:help (conversion-help expected actual)))

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
        [(and (string=? name "Map") (= (length arguments) 2))
         (define key (resolve-type (car arguments)))
         (unless (key-type? key)
           (bail 'CHECK-MAP-KEY-TYPE
                 (format "a Map key must be Int or String, found ~a" (type->string key))
                 (type-ref-span (car arguments))))
         (list 'Map key (resolve-type (cadr arguments)))]
        [(and (hash-has-key? structs name) (null? arguments))
         (list 'Struct name)]
        [else
         (bail 'CHECK-UNKNOWN-TYPE
               (format "unknown type \"~a\"" name)
               (type-ref-span reference)
               #:help (did-you-mean name (append '("Int" "Float" "Bool" "String" "Nil" "List" "Map")
                                                 (hash-keys structs))))]))

    ;; Scopes ---------------------------------------------------------------

    (define (push-scope!) (set! scopes (cons (make-hash) scopes)))
    (define (pop-scope!) (set! scopes (cdr scopes)))

    (define (lookup name)
      (let loop ([frames scopes])
        (cond
          [(null? frames) #f]
          [(hash-ref (car frames) name #f) => values]
          [else (loop (cdr frames))])))

    (define (visible-names)
      (append (append-map hash-keys scopes) (hash-keys functions)))

    (define (introduce! name type span [immutable? #f])
      (define existing (lookup name))
      (when existing
        (bail 'CHECK-SHADOWED-NAME
              (format "\"~a\" is already visible; Agentica does not allow shadowing" name)
              span
              #:help (if (cdr existing)
                         "choose another name"
                         (format "assign to it with \"~a = value\" instead of introducing it again, or choose another name"
                                 name))))
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
                   (name-ref-span expression)
                   #:help (did-you-mean (name-ref-name expression) (visible-names))))
           (car binding)]
          [(unary? expression) (check-unary expression)]
          [(binary? expression) (check-binary expression)]
          [(call? expression) (check-call expression)]
          [(construct? expression) (check-construct expression)]
          [(list-lit? expression) (check-list expression expected)]
          [(map-lit? expression) (check-map expression expected)]
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
                span
                #:expected (type->string left)
                #:actual (type->string right)
                #:labels (list (cons (node-span (binary-left expression)) (format "this is ~a" (type->string left)))
                               (cons (node-span (binary-right expression)) (format "this is ~a" (type->string right))))
                #:help (and (memq 'Int (list left right)) (memq 'Float (list left right))
                            "there is no Int to Float conversion; make both sides the same type"))))
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
                 (format "\"%\" expects two Ints, found ~a and ~a"
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

    (define (check-builtin-call expression)
      (define name (call-name expression))
      (define span (call-span expression))
      (define arguments (call-args expression))
      (define (arity! count)
        (unless (= (length arguments) count)
          (bail 'CHECK-ARITY
                (format "\"~a\" expects ~a argument(s), found ~a"
                        name count (length arguments))
                span)))
      (define (map-argument)
        (define type (check-expression (car arguments) #f))
        (unless (map-type? type) (mismatch! 'Map type (node-span (car arguments))))
        type)
      (case name
        [("Map.has_key?")
         (arity! 2)
         (define target (map-argument))
         (check-expression (cadr arguments) (cadr target))
         'Bool]
        [("Map.keys") (arity! 1) (list 'List (cadr (map-argument)))]
        [("Map.size") (arity! 1) (map-argument) 'Int]
        [("Map.put")
         (arity! 3)
         (define target (map-argument))
         (check-expression (cadr arguments) (cadr target))
         (check-expression (caddr arguments) (caddr target))
         target]
        [("List.size")
         (arity! 1)
         (define type (check-expression (car arguments) #f))
         (unless (list-type? type) (mismatch! '(List T) type (node-span (car arguments))))
         'Int]
        [("String.length")
         (arity! 1)
         (check-expression (car arguments) 'String)
         'Int]
        [("String.upcase" "String.downcase" "String.trim")
         (arity! 1)
         (check-expression (car arguments) 'String)
         'String]
        [("String.split")
         (arity! 2)
         (check-expression (car arguments) 'String)
         (check-expression (cadr arguments) 'String)
         '(List String)]
        [("String.join")
         (arity! 2)
         (check-expression (car arguments) '(List String))
         (check-expression (cadr arguments) 'String)
         'String]
        [("String.contains?" "String.starts_with?" "String.ends_with?")
         (arity! 2)
         (check-expression (car arguments) 'String)
         (check-expression (cadr arguments) 'String)
         'Bool]
        [("String.replace")
         (arity! 3)
         (check-expression (car arguments) 'String)
         (check-expression (cadr arguments) 'String)
         (check-expression (caddr arguments) 'String)
         'String]
        [("String.slice")
         (arity! 3)
         (check-expression (car arguments) 'String)
         (check-expression (cadr arguments) 'Int)
         (check-expression (caddr arguments) 'Int)
         'String]
        [("String.from_int")
         (arity! 1)
         (check-expression (car arguments) 'Int)
         'String]
        [("String.from_float")
         (arity! 1)
         (check-expression (car arguments) 'Float)
         'String]
        [("String.to_int!")
         (arity! 1)
         (check-expression (car arguments) 'String)
         'Int]
        [("String.to_float!")
         (arity! 1)
         (check-expression (car arguments) 'String)
         'Float]
        [("IO.puts" "IO.print" "IO.warn")
         (arity! 1)
         (check-expression (car arguments) 'String)
         'Nil]
        [("IO.inspect")
         (arity! 1)
         (check-expression (car arguments) #f)]
        [("IO.gets" "IO.read")
         (arity! 0)
         'String]
        [("IO.eof?")
         (arity! 0)
         'Bool]
        [("System.args")
         (arity! 0)
         '(List String)]
        [("System.exit")
         (arity! 1)
         (check-expression (car arguments) 'Int)
         'Nil]
        [else (bail 'CHECK-UNKNOWN-NAME (format "unknown function \"~a\"" name) span)]))

    (define (check-call expression)
      (if (string-contains? (call-name expression) ".")
          (check-builtin-call expression)
          (check-plain-call expression)))

    (define (check-plain-call expression)
      (define name (call-name expression))
      (define entry (hash-ref functions name #f))
      (unless entry
        (bail 'CHECK-UNKNOWN-NAME
              (format "unknown function \"~a\"" name)
              (call-span expression)
              #:help (did-you-mean name (hash-keys functions))))
      (define parameter-types (car entry))
      (define result-type (cadr entry))
      (define arguments (call-args expression))
      (unless (= (length arguments) (length parameter-types))
        (bail 'CHECK-ARITY
              (format "\"~a\" expects ~a argument(s), found ~a"
                      name (length parameter-types) (length arguments))
              (call-span expression)
              #:callee (format "~a(~a) -> ~a" name
                               (string-join (map type->string parameter-types) ", ")
                               (type->string result-type))))
      (for ([argument (in-list arguments)]
            [parameter-type (in-list parameter-types)])
        (check-expression argument parameter-type))
      result-type)

    (define (check-construct expression)
      (define name (construct-type-name expression))
      (unless (hash-has-key? structs name)
        (bail 'CHECK-UNKNOWN-TYPE
              (format "\"~a\" is not a declared struct" name)
              (construct-span expression)
              #:help (did-you-mean name (hash-keys structs))))
      (define fields (hash-ref structs name))
      (define seen '())
      (for ([argument (in-list (construct-args expression))])
        (define field-name (named-arg-name argument))
        (define field (assoc field-name fields))
        (unless field
          (bail 'CHECK-UNKNOWN-FIELD
                (format "\"~a\" has no field \"~a\"" name field-name)
                (named-arg-span argument)
                #:help (field-help field-name fields)))
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
                (construct-span expression)
                #:help (format "add \"~a: ...\" with a value of type ~a" (car field) (type->string (cdr field))))))
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

    (define (check-map expression expected)
      (define span (map-lit-span expression))
      (define entries (map-lit-entries expression))
      (when (and expected (not (map-type? expected)))
        (bail 'CHECK-TYPE-MISMATCH
              (format "expected ~a, found a map" (type->string expected))
              span))
      (define expected-key (and expected (cadr expected)))
      (define expected-value (and expected (caddr expected)))
      (cond
        [(null? entries)
         (unless expected
           (bail 'CHECK-EMPTY-LIST-TYPE
                 "an empty map needs an expected type, for example \"Map[String, Int]\""
                 span))
         expected]
        [else
         (define first-entry (car entries))
         (define key-type
           (check-expression (map-entry-key first-entry) expected-key))
         (unless (key-type? key-type)
           (bail 'CHECK-MAP-KEY-TYPE
                 (format "a Map key must be Int or String, found ~a" (type->string key-type))
                 (node-span (map-entry-key first-entry))))
         (define value-type
           (check-expression (map-entry-value first-entry) expected-value))
         (for ([entry (in-list (cdr entries))])
           (check-expression (map-entry-key entry) key-type)
           (check-expression (map-entry-value entry) value-type))
         (list 'Map key-type value-type)]))

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
              (field-access-span expression)
              #:help (field-help (field-access-name expression) (hash-ref structs (cadr target)))))
      (cdr field))

    (define (check-index-access expression)
      (define target (check-expression (index-access-target expression) #f))
      (cond
        [(map-type? target)
         (check-expression (index-access-index expression) (cadr target))
         (caddr target)]
        [(list-type? target)
         (check-expression (index-access-index expression) 'Int)
         (cadr target)]
        [else
         (bail 'CHECK-NOT-INDEXABLE
               (format "indexing needs a list or a map, found ~a" (type->string target))
               (index-access-span expression))]))

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
                 (binding-span statement)
                 #:help "\"for\" variables cannot be assigned; copy the value to a new name"))
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
      (set! current-signature
            (format "~a(~a) -> ~a"
                    (function-decl-name declaration)
                    (string-join (for/list ([parameter (in-list (function-decl-params declaration))])
                                   (format "~a: ~a" (param-name parameter)
                                           (type->string (resolve-type (param-type parameter)))))
                                 ", ")
                    (type->string result-type)))
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
              (function-decl-span declaration)
              #:help (missing-return-help (function-decl-body declaration) (type->string result-type)))))

    ;; Program --------------------------------------------------------------

    (hash-set! functions "puts" (list (list 'String) 'Nil))
    (register-structs!)
    (register-functions!)
    (check-main!)
    (for ([declaration (in-list (program-declarations program))])
      (when (function-decl? declaration)
        (check-function declaration)))
    program))
