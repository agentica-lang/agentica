#lang racket

(require "builtins.rkt" "builtin-types.rkt"
         "ast.rkt"
         "diagnostic.rkt"
         "source.rkt")

(provide check reserved-type-names)

(define int-max (sub1 (expt 2 63)))

(define reserved-type-names
  (append '("Int" "Float" "Bool" "String" "Nil" "Void" "List" "Map" "Result" "IO" "System" "Json" "JSON" "Fn" "BDD" "Task" "File" "Dir" "Path" "TCP" "TLS" "HTTP" "Time" "Random" "Range")
          (map symbol->string opaque-types) (hash-keys builtin-records)))

(define (result-type? type)
  (and (pair? type) (eq? (car type) 'Result)))

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

(define (enum-type? type)
  (and (pair? type) (eq? (car type) 'Enum)))

(define method-modules
  (hasheq 'String "String" 'List "List" 'Map "Map" 'Float "Float" 'Result "Result" 'Json "JSON"
          'Int "Int" 'Range "Range"))

(define method-aliases
  (hash '(String . "size") "String.length"
        '(String . "to_i") "String.to_int" '(String . "to_i!") "String.to_int!"
        '(String . "to_f") "String.to_float" '(String . "to_f!") "String.to_float!"
        '(String . "strip") "String.trim" '(String . "include?") "String.contains?"
        '(String . "start_with?") "String.starts_with?" '(String . "end_with?") "String.ends_with?"
        '(String . "to_s") 'self
        '(List . "length") "List.size" '(List . "push") "List.append" '(List . "join") "String.join"
        '(Int . "to_s") "String.from_int" '(Int . "to_f") "Float.from_int"
        '(Float . "to_s") "String.from_float"
        '(Float . "to_i") "Float.to_int" '(Float . "to_i!") "Float.to_int!"))

(define (type-head type)
  (if (pair? type) (car type) type))

(define (receiver-kind type)
  (and (memq (type-head type) '(String List Map Float Result Json Int Range))
       (type-head type)))

(define (catalog-method kind name)
  (define module (hash-ref method-modules kind #f))
  (define entry (and module (builtin-ref (string-append module "." name))))
  (and entry
       (pair? (builtin-parameters entry))
       (eq? (type-head (cadr (car (builtin-parameters entry)))) kind)
       (builtin-name entry)))

(define (resolve-method kind name)
  (hash-ref method-aliases (cons kind name) (lambda () (catalog-method kind name))))

(define (method-names kind)
  (define module (hash-ref method-modules kind #f))
  (remove-duplicates
   (append
    (for/list ([key (in-hash-keys method-aliases)] #:when (eq? (car key) kind)) (cdr key))
    (for/list ([name (in-hash-keys builtins)]
               #:when (and module (string-prefix? name (string-append module "."))
                           (catalog-method kind (substring name (add1 (string-length module))))))
      (substring name (add1 (string-length module)))))))

(define (literal-type value)
  (cond
    [(boolean? value) 'Bool]
    [(exact-integer? value) 'Int]
    [(flonum? value) 'Float]
    [(string? value) 'String]
    [(eq? value 'nil) 'Nil]
    [else '?]))

(define foreign-names
  (hash "len" "use x.size for lists and maps, or s.length for strings"
        "str" "use x.to_s, or interpolation: \"#{x}\""
        "println" "use puts(x)"
        "inspect" "use x.inspect for the debug text, or IO.inspect(x) to print it and get x back"
        "input" "use gets, which returns Result[String]; gets! halts at the end of input"
        "read_line" "use gets, which returns Result[String]; gets! halts at the end of input"
        "readline" "use gets, which returns Result[String]; gets! halts at the end of input"
        "range" "write a range: a..b includes b, a...b excludes it, as in for i in 0...n"
        "int" "use s.to_i or f.to_i (both give a Result), or s.to_i! / f.to_i! to halt on failure"
        "elif" "write elsif: if a ... elsif b ... else ... end"
        "elseif" "write elsif: if a ... elsif b ... else ... end"
        "float" "use n.to_f for an Int, s.to_f (a Result) or s.to_f! for a String"
        "Int.to_float" "use n.to_f"
        "Int.to_string" "use n.to_s"
        "Int.parse" "use s.to_i (a Result) or s.to_i!"
        "Float.to_string" "use x.to_s"
        "null" "use nil"
        "None" "use nil"
        "nil?" "compare with nil: x == nil"
        "break" "break is a statement on its own line inside while or for"
        "continue" "write next, on its own line, to skip to the next iteration"
        "next" "next is a statement on its own line inside while or for"
        "Hash.new" "use a map literal with a type: m: Map[String, Int] = {}"
        "Array.new" "use a list literal with a type: xs: List[Int] = []"))

(define foreign-methods
  (hash "to_string" '("to_s") "to_str" '("to_s") "len" '("size" "length")
        "lower" '("downcase") "upper" '("upcase")
        "startswith" '("start_with?") "endswith" '("end_with?")
        "to_int" '("to_i" "to_int") "to_float" '("to_f" "to_float")))

(define (foreign-method-help kind name)
  (cond
    [(equal? name "nil?") "values are never nil unless their type is Nil; compare with nil: x == nil"]
    [else
     (define target
       (for/first ([candidate (in-list (hash-ref foreign-methods name '()))]
                   #:when (resolve-method kind candidate))
         candidate))
     (and target (format "use .~a" target))]))

(define (conversion-help expected actual)
  (cond
    [(and (result-type? actual) (equal? (cadr actual) expected))
     (format "this is ~a; unwrap it with a ! form (~a), with Result.unwrap!(...), or with try inside a function that returns Result"
             (type->string actual)
             (case expected
               [(Int) "s.to_i!"]
               [(Float) "s.to_f!"]
               [(String) "gets!"]
               [else "such as s.to_i!"]))]
    [(and (eq? expected 'String) (eq? actual 'Int)) "convert it with String.from_int(...)"]
    [(and (eq? expected 'String) (eq? actual 'Float)) "convert it with String.from_float(...)"]
    [(and (eq? expected 'Int) (eq? actual 'String)) "convert it with String.to_int!(...)"]
    [(and (eq? expected 'Float) (eq? actual 'String)) "convert it with String.to_float!(...)"]
    [(and (eq? expected 'Float) (eq? actual 'Int)) "convert it with Float.from_int(...)"]
    [(and (eq? expected 'Int) (eq? actual 'Float)) "convert it with Float.to_int!(...), which truncates"]
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
      [(case-stmt? statement)
       (for/or ([arm (in-list (case-stmt-arms statement))])
         (contains-return? (case-arm-body arm)))]
      [else #f])))

(define (missing-return-help body type-name)
  (cond
    [(not (contains-return? body))
     (format "add \"return <value>\" of type ~a at the end" type-name)]
    [(and (pair? body) (if-stmt? (last body)) (not (if-stmt-else-body (last body))))
     (format "the last \"if\" has no \"else\"; add an \"else\" that returns ~a, or return after it" type-name)]
    [else #f]))

(define (takes-function? entry)
  (for/or ([parameter (in-list (builtin-parameters entry))])
    (and (pair? (cadr parameter)) (eq? (car (cadr parameter)) 'Fn))))

(define (keeps-first-type? entry)
  (and entry
       (pair? (builtin-parameters entry))
       (equal? (cadr (car (builtin-parameters entry))) (builtin-result entry))))

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
    [(case-stmt? statement)
     (for/and ([arm (in-list (case-stmt-arms statement))])
       (block-returns? (case-arm-body arm)))]
    [else #f]))

(define (check program #:types [types #f])
  (define structs (hash-copy builtin-records))
  (define enums (make-hash))
  (define functions (make-hash))
  (define current-type-parameters '())
  (define scopes '())
  (define current-result 'Void)
  (define current-signature #f)
  (define capture-boundary #f)
  (define loop-depth 0)

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

    (define (type-variable? type)
      (and (pair? type) (eq? (car type) 'TypeVar)))

    (define (substitute-type type substitutions)
      (cond
        [(type-variable? type) (hash-ref substitutions (cadr type) type)]
        [(pair? type) (cons (car type) (map (lambda (item) (substitute-type item substitutions)) (cdr type)))]
        [else type]))

    (define (unify-type! template actual substitutions span)
      (cond
        [(type-variable? template)
         (define name (cadr template))
         (define previous (hash-ref substitutions name #f))
         (if previous
             (ensure actual previous span)
             (hash-set! substitutions name actual))]
        [(and (pair? template) (pair? actual)
              (eq? (car template) (car actual))
              (= (length (cdr template)) (length (cdr actual)))
              (not (memq (car template) '(Struct))))
         (for ([left (in-list (cdr template))] [right (in-list (cdr actual))])
           (unify-type! left right substitutions span))]
        [else (ensure actual template span)]))

    (define (resolve-type reference [completion? #f])
      (define name (type-ref-name reference))
      (define arguments (type-ref-args reference))
      (cond
        [(and (member name current-type-parameters) (null? arguments))
         (list 'TypeVar name)]
        [(and (string=? name "Void") (null? arguments))
         (unless completion?
           (bail 'CHECK-VOID-TYPE "Void is only valid in a completion type position" (type-ref-span reference)))
         'Void]
        [(and (member name '("Int" "Float" "Bool" "String" "Nil" "Json" "Range"))
              (null? arguments))
         (string->symbol name)]
        [(and (member (string->symbol name) opaque-types) (null? arguments)) (string->symbol name)]
        [(and (string=? name "Result") (= (length arguments) 1))
         (list 'Result (resolve-type (car arguments) #t))]
        [(and (string=? name "Task") (= (length arguments) 1))
         (list 'Task (resolve-type (car arguments) #t))]
        [(and (string=? name "Fn") (pair? arguments))
         (cons 'Fn (append (map resolve-type (drop-right arguments 1))
                          (list (resolve-type (last arguments) #t))))]
        [(and (string=? name "List") (= (length arguments) 1))
         (list 'List (resolve-type (car arguments)))]
        [(and (string=? name "Map") (= (length arguments) 2))
         (define key (resolve-type (car arguments)))
         (unless (key-type? key)
           (bail 'CHECK-MAP-KEY-TYPE
                 (format "a Map key must be Int or String, found ~a" (type->string key))
                 (type-ref-span (car arguments))))
         (list 'Map key (resolve-type (cadr arguments)))]
        [(hash-has-key? enums name)
         (define parameters (car (hash-ref enums name)))
         (unless (= (length parameters) (length arguments))
           (bail 'CHECK-UNKNOWN-TYPE
                 (format "enum ~a expects ~a type argument(s), found ~a"
                         (display-name name) (length parameters) (length arguments))
                 (type-ref-span reference)))
         (cons 'Enum (cons name (map resolve-type arguments)))]
        [(and (hash-has-key? structs name) (null? arguments))
         (list 'Struct name)]
        [else
         (bail 'CHECK-UNKNOWN-TYPE
               (format "unknown type \"~a\"" (display-name name))
               (type-ref-span reference)
               #:help (did-you-mean name
                                    (append (hash-keys structs) (hash-keys enums))
                                    #:shared (append '("Int" "Float" "Bool" "String" "Nil" "Void" "List" "Map" "Result" "Json" "Fn" "Task" "Range")
                                                     (map symbol->string opaque-types))))]))

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
      (append (append-map hash-keys scopes) (hash-keys functions) (hash-keys builtins)))

    (define (reserve-constructor! name span)
      (when (member name '("ok" "error"))
        (bail 'CHECK-REDEFINED-NAME (format "\"~a\" is a builtin constructor" name) span)))

    (define (reserve-local! name span)
      (reserve-constructor! name span)
      (when (member name '("puts" "print" "gets" "gets!"))
        (bail 'CHECK-REDEFINED-NAME (format "\"~a\" is a builtin function" name) span
              #:help "choose another name, such as line or text")))

    (define (introduce! name type span [immutable? #f])
      (reserve-local! name span)
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

    (define (register-enum-names!)
      (for ([declaration (in-list (program-declarations program))]
            #:when (enum-decl? declaration))
        (define name (enum-decl-name declaration))
        (define parameters (enum-decl-type-parameters declaration))
        (when (or (member name reserved-type-names)
                  (hash-has-key? structs name)
                  (hash-has-key? enums name)
                  (hash-has-key? functions name))
          (bail 'CHECK-REDEFINED-NAME (format "\"~a\" is already defined" (display-name name))
                (enum-decl-span declaration)))
        (when (check-duplicates parameters)
          (bail 'CHECK-REDEFINED-NAME "duplicate enum type parameter"
                (enum-decl-span declaration)))
        (for ([parameter (in-list parameters)])
          (when (member parameter reserved-type-names)
            (bail 'CHECK-REDEFINED-NAME
                  (format "\"~a\" cannot be used as an enum type parameter" parameter)
                  (enum-decl-span declaration))))
        (hash-set! enums name (cons parameters (make-hash)))))

    (define (register-enum-variants!)
      (for ([declaration (in-list (program-declarations program))]
            #:when (enum-decl? declaration))
        (define name (enum-decl-name declaration))
        (define parameters (enum-decl-type-parameters declaration))
        (define variants (cdr (hash-ref enums name)))
        (set! current-type-parameters parameters)
        (for ([variant (in-list (enum-decl-variants declaration))])
          (define variant-name (enum-variant-name variant))
          (when (hash-has-key? variants variant-name)
            (bail 'CHECK-REDEFINED-NAME
                  (format "duplicate variant \"~a\" in enum \"~a\"" variant-name (display-name name))
                  (enum-variant-span variant)))
          (hash-set! variants variant-name
                     (map resolve-type (enum-variant-payload-types variant))))
        (set! current-type-parameters '())))

    (define (register-structs!)
      (for ([declaration (in-list (program-declarations program))])
        (when (struct-decl? declaration)
          (define name (struct-decl-name declaration))
          (when (or (member name reserved-type-names)
                    (hash-has-key? structs name)
                    (hash-has-key? enums name)
                    (hash-has-key? functions name))
            (bail 'CHECK-REDEFINED-NAME
                  (format "\"~a\" is already defined" (display-name name))
                  (struct-decl-span declaration)))
          (hash-set! structs name '())))
      (for ([declaration (in-list (program-declarations program))])
        (when (struct-decl? declaration)
          (define seen '())
          (hash-set! structs (struct-decl-name declaration)
                     (for/list ([field (in-list (struct-decl-fields declaration))])
                       (define field-name (field-decl-name field))
                       (reserve-constructor! field-name (field-decl-span field))
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
          (when (or (builtin-ref name)
                    (hash-has-key? functions name)
                    (hash-has-key? structs name)
                    (hash-has-key? enums name))
            (bail 'CHECK-REDEFINED-NAME
                  (format "\"~a\" is already defined" (display-name name))
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
                     (list parameter-types (resolve-type (function-decl-result declaration) #t))))))

    (define (check-main!)
      (define mains
        (for/list ([declaration (in-list (program-declarations program))]
                   #:when (and (function-decl? declaration)
                               (string=? (function-decl-name declaration) "main")))
          declaration))
      (cond
        [(null? mains)
         (bail 'CHECK-MAIN "a program must declare exactly one main() -> Void" (program-span program))]
        [else
         (define main (car mains))
         (unless (and (null? (function-decl-params main))
                      (eq? (resolve-type (function-decl-result main) #t) 'Void))
           (bail 'CHECK-MAIN "main must take no parameters and return Void"
                 (function-decl-span main)))]))

    ;; Expressions ----------------------------------------------------------

    (define (check-expression expression expected #:completion? [completion? #f])
      (define actual
        (cond
          [(type-expression? expression)
           (bail 'CHECK-TYPE-MISMATCH "a type name is only valid as a JSON type argument"
                 (node-span expression)
                 #:help (hash-ref foreign-names (type-expression-name expression) #f))]
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
                   (if (or (hash-has-key? functions (name-ref-name expression))
                           (builtin-ref (name-ref-name expression)))
                       (format "\"~a\" is a function; functions are not values"
                               (name-ref-name expression))
                       (format "unknown name \"~a\"" (name-ref-name expression)))
                   (name-ref-span expression)
                   #:help (and (not (hash-has-key? functions (name-ref-name expression)))
                               (not (builtin-ref (name-ref-name expression)))
                               (or (did-you-mean (name-ref-name expression) (visible-names))
                                   (hash-ref foreign-names (name-ref-name expression) #f)))))
           (car binding)]
          [(unary? expression) (check-unary expression)]
          [(binary? expression) (check-binary expression)]
          [(call? expression) (check-call expression expected)]
          [(enum-constructor? expression)
           (check-enum-constructor (enum-constructor-enum-name expression)
                                   (enum-constructor-variant-name expression)
                                   (enum-constructor-args expression)
                                   (enum-constructor-span expression)
                                   expected)]
          [(function-ref? expression)
           (define signature (hash-ref functions (function-ref-name expression) #f))
           (unless signature
             (bail 'CHECK-UNKNOWN-NAME "a function reference requires a declared function"
                   (function-ref-span expression)))
           (cons 'Fn (append (car signature) (list (cadr signature))))]
          [(invoke? expression)
           (define target (check-expression (invoke-target expression) #f))
           (unless (and (pair? target) (eq? (car target) 'Fn))
             (bail 'CHECK-TYPE-MISMATCH ".call requires a function value" (invoke-span expression)))
           (define parameters (drop-right (cdr target) 1))
           (unless (= (length parameters) (length (invoke-args expression)))
             (bail 'CHECK-ARITY "wrong number of function arguments" (invoke-span expression)))
           (for ([argument (in-list (invoke-args expression))] [parameter (in-list parameters)])
             (check-expression argument parameter))
           (last target)]
          [(try-expr? expression) (check-try expression expected)]
          [(construct? expression) (check-construct expression expected)]
          [(list-lit? expression) (check-list expression expected)]
          [(map-lit? expression) (check-map expression expected)]
          [(field-access? expression) (check-field-access expression expected)]
          [(method-call? expression)
           (check-method expression (method-call-target expression) (method-call-name expression)
                         (method-call-args expression) (method-call-span expression) expected
                         (lambda (resolved) (set-method-call-resolved! expression resolved)))]
          [(typed-target? expression) (typed-target-type expression)]
          [(block-lit? expression) (check-block-lit expression expected)]
          [(interpolation? expression)
           (for ([part (in-list (interpolation-parts expression))] #:unless (string? part))
             (ensure-printable! (check-expression part #f) (node-span part)))
           'String]
          [(index-access? expression) (check-index-access expression)]
          [else (bail 'CHECK-INTERNAL "unsupported expression" (node-span expression))]))
      (when types (hash-set! types expression actual))
      (when (and (eq? actual 'Void) (not completion?))
        (bail 'CHECK-VOID-VALUE "a Void call has no value; use it as a statement" (node-span expression)))
      (ensure actual expected (node-span expression)))

    (define (check-try expression expected)
      (unless (result-type? current-result)
        (bail 'CHECK-TRY-CONTEXT "try requires a function returning Result" (try-expr-span expression)
              #:help "return Result[T] from this function, or handle the Result explicitly"))
      (define operand (try-expr-operand expression))
      (define type (check-expression operand (and expected (list 'Result expected))))
      (unless (result-type? type)
        (mismatch! '(Result T) type (node-span operand)))
      (cadr type))

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
                 (format "\"not\" (or \"!\") expects Bool, found ~a" (type->string operand))
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
                            "make both sides the same type: Float.from_int(...) turns the Int into a Float, Float.to_int!(...) truncates the Float"))))
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
        [(dot-dot dot-dot-dot)
         (unless (and (eq? left 'Int) (eq? right 'Int))
           (bail 'CHECK-TYPE-MISMATCH
                 (format "a range expects two Ints, found ~a and ~a"
                         (type->string left) (type->string right))
                 span))
         'Range]
        [(equal not-equal)
         (same!)
         (unless (or (primitive-type? left) (eq? left 'Range))
           (bail 'CHECK-TYPE-MISMATCH
                 (format "equality is only defined for primitive values and ranges, found ~a"
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

    (define (encodable-type? type [seen '()])
      (cond
        [(or (primitive-type? type) (eq? type 'Json)) #t]
        [(list-type? type) (encodable-type? (cadr type) seen)]
        [(map-type? type)
         (and (eq? (cadr type) 'String) (encodable-type? (caddr type) seen))]
        [(struct-type? type)
         (define name (cadr type))
         (or (member name seen)
             (for/and ([field (in-list (hash-ref structs name))])
               (encodable-type? (cdr field) (cons name seen))))]
        [else #f]))

    (define (printable-type? type [seen '()])
      (cond
        [(or (primitive-type? type) (memq type '(Json Range)) (type-variable? type)) #t]
        [(list-type? type) (printable-type? (cadr type) seen)]
        [(map-type? type) (and (printable-type? (cadr type) seen) (printable-type? (caddr type) seen))]
        [(result-type? type) (or (eq? (cadr type) 'Void) (printable-type? (cadr type) seen))]
        [(or (struct-type? type) (enum-type? type))
         (define key (cons (car type) (cadr type)))
         (and (for/and ([argument (in-list (cddr type))])
                (printable-type? argument seen))
              (or (and (member key seen) #t)
                  (let ([seen (cons key seen)])
                    (if (struct-type? type)
                        (for/and ([field (in-list (hash-ref structs (cadr type)))])
                          (printable-type? (cdr field) seen))
                        (for*/and ([payload (in-hash-values (cdr (hash-ref enums (cadr type))))]
                                   [field (in-list payload)])
                          (printable-type? field seen))))))]
        [else #f]))

    (define (ensure-printable! type span)
      (unless (printable-type? type)
        (bail 'CHECK-TYPE-MISMATCH
              (format "~a has no to_s, so it cannot be printed or interpolated" (type->string type))
              span
              #:help "only data values have to_s: numbers, Bool, String, nil, Json, ranges, and lists, maps, Results, structs and enums of those")))

    (define (decodable-type? type [seen '()])
      (cond
        [(memq type '(Int Float Bool String)) #t]
        [(list-type? type) (decodable-type? (cadr type) seen)]
        [(map-type? type)
         (and (eq? (cadr type) 'String) (decodable-type? (caddr type) seen))]
        [(struct-type? type)
         (define name (cadr type))
         (or (member name seen)
             (for/and ([field (in-list (hash-ref structs name))])
               (decodable-type? (cdr field) (cons name seen))))]
        [else #f]))

    (define (check-builtin-call expression expected entry)
      (define span (call-span expression))
      (define arguments (call-args expression))
      (define selected (builtin-ref (builtin-name entry) (length arguments)))
      (unless selected
        (bail 'CHECK-ARITY
              (format "\"~a\" expects ~a argument(s), found ~a"
                      (builtin-name entry)
                      (string-join
                       (map (lambda (variant) (number->string (length (builtin-parameters variant))))
                            (cons entry (builtin-alternatives entry))) " or ")
                      (length arguments))
              span #:callee (builtin-signature entry)))
      (define parameters (builtin-parameters selected))
      (when (and (pair? arguments) (block-lit? (last arguments)))
        (define last-type (cadr (last parameters)))
        (unless (and (pair? last-type) (eq? (car last-type) 'Fn))
          (bail 'CHECK-BLOCK-TARGET
                (format "\"~a\" does not take a block: its last parameter is not a function"
                        (builtin-name selected))
                (block-lit-span (last arguments))
                #:help "a block is only allowed when the last parameter is a function (Fn[...])")))
      (define (annotated-parameter block index)
        (define block-parameters (block-lit-params block))
        (and (> (length block-parameters) index)
             (block-param-type (list-ref block-parameters index))
             (resolve-type (block-param-type (list-ref block-parameters index)))))
      (define (map-argument [context #f])
        (define type (check-expression (car arguments) context))
        (unless (map-type? type) (mismatch! '(Map K V) type (node-span (car arguments))))
        type)
      (define (list-argument [context #f])
        (define type (check-expression (car arguments) context))
        (unless (list-type? type) (mismatch! '(List T) type (node-span (car arguments))))
        type)
      (define (empty-list? argument)
        (and (list-lit? argument) (null? (list-lit-elements argument))))
      (define (map-context value-type)
        (and value-type
             (list 'Map (check-expression (cadr arguments) #f) value-type)))
      (define (result-argument [context #f])
        (define type (check-expression (car arguments) context))
        (unless (result-type? type) (mismatch! '(Result T) type (node-span (car arguments))))
        type)
      (case (builtin-rule selected)
        [(http-producer)
         (for ([argument (in-list (take arguments 5))] [parameter (in-list (take parameters 5))])
           (check-expression argument (cadr parameter)))
         (define callback (check-expression (list-ref arguments 5) #f))
         (unless (and (list? callback) (= (length callback) 4) (eq? (car callback) 'Fn)
                      (equal? (caddr callback) 'HttpWriter) (equal? (cadddr callback) '(Result Void)))
           (bail 'CHECK-TYPE-MISMATCH "producer must have type Fn[A, HttpWriter, Result[Void]]"
                 (node-span (list-ref arguments 5))))
         (check-expression (list-ref arguments 6) (cadr callback))
         '(Result (Struct "Response"))]
        [(task-spawn)
         (define callback (check-expression (car arguments) #f))
         (unless (and (list? callback) (= (length callback) 3) (eq? (car callback) 'Fn))
           (bail 'CHECK-TYPE-MISMATCH "Task.spawn requires a function with one parameter"
                 (node-span (car arguments))))
         (check-expression (cadr arguments) (cadr callback))
         (list 'Task (caddr callback))]
        [(task-await)
         (define target (check-expression (car arguments) (and expected (list 'Task expected))))
         (unless (and (pair? target) (eq? (car target) 'Task))
           (bail 'CHECK-TYPE-MISMATCH "Task.await requires a task" (node-span (car arguments))))
         (cadr target)]
        [(map-has)
         (define target (map-argument))
         (check-expression (cadr arguments) (cadr target))
         'Bool]
        [(map-keys) (list 'List (cadr (map-argument)))]
        [(map-values) (list 'List (caddr (map-argument)))]
        [(map-get map-get-default)
         (define with-default? (eq? (builtin-rule selected) 'map-get-default))
         (define value-context (if with-default? expected
                                   (and (result-type? expected) (cadr expected))))
         (define default-context
           (and (not value-context) with-default? (map-lit? (car arguments))
                (null? (map-lit-entries (car arguments)))
                (check-expression (caddr arguments) #f)))
         (define target
           (map-argument (map-context (or value-context default-context))))
         (check-expression (cadr arguments) (cadr target))
         (when with-default? (check-expression (caddr arguments) (caddr target)))
         (if with-default? (caddr target) (list 'Result (caddr target)))]
        [(map-delete)
         (define target (map-argument (and (map-type? expected) expected)))
         (check-expression (cadr arguments) (cadr target))
         target]
        [(map-size) (map-argument) 'Int]
        [(map-put)
         (define target (map-argument))
         (check-expression (cadr arguments) (cadr target))
         (check-expression (caddr arguments) (caddr target))
         target]
        [(list-size) (list-argument) 'Int]
        [(list-reverse) (list-argument (and (list-type? expected) expected))]
        [(list-sort)
         (define target (list-argument (and (list-type? expected) expected)))
         (unless (memq (cadr target) '(Int Float String))
           (bail 'CHECK-TYPE-MISMATCH
                 (format "List.sort needs List[Int], List[Float] or List[String], found ~a"
                         (type->string target))
                 (node-span (car arguments))))
         target]
        [(list-sort-by)
         (define callback-expression (cadr arguments))
         (define block-target
           (and (block-lit? callback-expression)
                (list-argument (let ([element (annotated-parameter callback-expression 0)])
                                 (and element (list 'List element))))))
         (define callback
           (if block-target
               (check-block-body callback-expression (list (cadr block-target)) #f)
               (check-expression callback-expression #f)))
         (unless (and (list? callback) (= (length callback) 3) (eq? (car callback) 'Fn))
           (bail 'CHECK-TYPE-MISMATCH "sort_by requires a key function with one parameter"
                 (node-span callback-expression)))
         (unless (memq (caddr callback) '(Int Float String))
           (bail 'CHECK-TYPE-MISMATCH "sort_by keys must be Int, Float or String"
                 (node-span callback-expression)))
         (or block-target (list-argument (list 'List (cadr callback))))]
        [(list-map list-filter list-reduce list-each list-any list-all)
         (define rule (builtin-rule selected))
         (define reduce? (eq? rule 'list-reduce))
         (define callback-expression (last arguments))
         (define callback
           (cond
             [(block-lit? callback-expression)
              (define annotated-element (annotated-parameter callback-expression (if reduce? 1 0)))
              (define element
                (cadr (list-argument (and annotated-element (list 'List annotated-element)))))
              (cond
                [reduce?
                 (define accumulator
                   (check-expression (cadr arguments)
                                     (or expected (annotated-parameter callback-expression 0))))
                 (check-block-body callback-expression (list accumulator element) accumulator)]
                [(memq rule '(list-filter list-any list-all))
                 (check-block-body callback-expression (list element) 'Bool)]
                [(eq? rule 'list-each)
                 (check-block-body callback-expression (list element) 'Void)]
                [else (check-block-body callback-expression (list element) #f)])]
             [else (check-expression callback-expression #f)]))
         (define arity (if reduce? 2 1))
         (unless (and (list? callback) (= (length callback) (+ arity 2))
                      (eq? (car callback) 'Fn))
           (bail 'CHECK-TYPE-MISMATCH "wrong collection callback type"
                 (node-span callback-expression)))
         (define element (if reduce? (caddr callback) (cadr callback)))
         (define result (last callback))
         (unless (block-lit? callback-expression)
           (list-argument (list 'List element)))
         (cond
           [reduce?
            (unless (equal? (cadr callback) result)
              (mismatch! (cadr callback) result (node-span callback-expression)))
            (unless (block-lit? callback-expression)
              (check-expression (cadr arguments) result))
            result]
           [(memq rule '(list-filter list-any list-all))
            (unless (eq? result 'Bool)
              (mismatch! 'Bool result (node-span callback-expression)))
            (if (eq? rule 'list-filter) (list 'List element) 'Bool)]
           [(eq? rule 'list-each)
            (unless (eq? result 'Void)
              (mismatch! 'Void result (node-span callback-expression)))
            'Void]
           [else
            (when (eq? result 'Void)
              (bail 'CHECK-VOID-VALUE "map callbacks must return data"
                    (node-span callback-expression)))
            (list 'List result)])]
        [(list-concat)
         (define target
           (list-argument
            (or (and (list-type? expected) expected)
                (and (empty-list? (car arguments))
                     (check-expression (cadr arguments) #f)))))
         (check-expression (cadr arguments) target)
         target]
        [(list-count list-at)
         (define at? (eq? (builtin-rule selected) 'list-at))
         (define target
           (list-argument (if at?
                              (and expected (list 'List expected))
                              (and (list-type? expected) expected))))
         (check-expression (cadr arguments) 'Int)
         (if at? (cadr target) target)]
        [(list-append list-set)
         (define value (last arguments))
         (define target
           (list-argument
            (or (and (list-type? expected) expected)
                (and (empty-list? (car arguments))
                     (list 'List (check-expression value #f))))))
         (when (eq? (builtin-rule selected) 'list-set)
           (check-expression (cadr arguments) 'Int))
         (check-expression value (cadr target))
         target]
        [(list-repeat)
         (define element (check-expression (car arguments)
                                           (and (list-type? expected) (cadr expected))))
         (check-expression (cadr arguments) 'Int)
         (list 'List element)]
        [(json-decode json-schema)
         (define decode? (eq? (builtin-rule selected) 'json-decode))
         (when decode? (check-expression (car arguments) 'String))
         (define target (if decode? (cadr arguments) (car arguments)))
         (unless (type-expression? target)
           (bail 'CHECK-TYPE-MISMATCH "JSON type argument requires a struct name" (node-span target)))
         (define type (resolve-type (type-ref (type-expression-name target) '() (node-span target))))
         (unless (and (struct-type? type) (decodable-type? type))
           (bail 'CHECK-NOT-DECODABLE "target contains types that cannot be decoded" (node-span target)))
         (if decode? (list 'Result type) 'Json)]
        [(json-encode json-from)
         (define type (check-expression (car arguments) #f))
         (unless (encodable-type? type)
           (bail 'CHECK-NOT-ENCODABLE
                 (format "cannot JSON.encode ~a or its nested types" (type->string type))
                 (node-span (car arguments))))
         (if (eq? (builtin-rule selected) 'json-from) 'Json 'String)]
        [(identity) (check-expression (car arguments) expected)]
        [(show) (ensure-printable! (check-expression (car arguments) #f) (node-span (car arguments))) 'Void]
        [(ok)
         (list 'Result (check-expression (car arguments)
                                        (and (result-type? expected) (cadr expected))))]
        [(ok-void) '(Result Void)]
        [(error)
         (check-expression (car arguments) 'String)
         (when (and expected (not (result-type? expected)))
           (mismatch! expected '(Result T) span))
         (unless expected
           (bail 'CHECK-RESULT-TYPE "an error needs an expected Result type" span
                 #:help "add a Result[T] annotation, for example r: Result[Int] = error(message)"))
         expected]
        [(result-ok) (result-argument) 'Bool]
        [(result-message) (result-argument) 'String]
        [(result-unwrap)
         (cadr (result-argument (and expected (list 'Result expected))))]
        [(result-default)
         (define type (check-expression (cadr arguments) expected))
         (result-argument (list 'Result type))
         type]
        [else
         (for ([argument (in-list arguments)] [parameter (in-list parameters)])
           (check-expression argument (cadr parameter)))
         (builtin-result selected)]))

    (define (check-call expression expected)
      (define entry (builtin-ref (call-name expression)))
      (if entry
          (check-builtin-call expression expected entry)
          (check-plain-call expression)))

    (define (check-plain-call expression)
      (define name (call-name expression))
      (define entry (hash-ref functions name #f))
      (unless entry
        (bail 'CHECK-UNKNOWN-NAME
              (format "unknown function \"~a\"" (display-name name))
              (call-span expression)
              #:help (or (hash-ref foreign-names name #f)
                         (did-you-mean name (hash-keys functions) #:shared (hash-keys builtins)))))
      (define parameter-types (car entry))
      (define result-type (cadr entry))
      (define arguments (call-args expression))
      (unless (= (length arguments) (length parameter-types))
        (bail 'CHECK-ARITY
              (format "\"~a\" expects ~a argument(s), found ~a"
                      (display-name name) (length parameter-types) (length arguments))
              (call-span expression)
              #:callee (format "~a(~a) -> ~a" (display-name name)
                               (string-join (map type->string parameter-types) ", ")
                               (type->string result-type))))
      (for ([argument (in-list arguments)]
            [parameter-type (in-list parameter-types)])
        (check-expression argument parameter-type))
      result-type)

    (define (has-type-variables? type)
      (or (type-variable? type)
          (and (pair? type) (ormap has-type-variables? (cdr type)))))

    (define (check-enum-constructor enum-name variant-name arguments span expected)
      (define definition (hash-ref enums enum-name #f))
      (unless definition
        (bail 'CHECK-UNKNOWN-TYPE (format "unknown enum \"~a\"" enum-name) span
              #:help (and (equal? enum-name "Result")
                          "Result has only Ok and Err: Result.Ok(value) or ok(value), Result.Err(\"message\") or error(\"message\")")))
      (define parameters (car definition))
      (define variants (cdr definition))
      (define payload-types (hash-ref variants variant-name #f))
      (unless payload-types
        (bail 'CHECK-UNKNOWN-VARIANT
              (format "enum \"~a\" has no variant \"~a\"" (display-name enum-name) variant-name)
              span))
      (unless (= (length arguments) (length payload-types))
        (bail 'CHECK-ARITY
              (format "variant ~a.~a expects ~a argument(s), found ~a"
                      (display-name enum-name) variant-name (length payload-types) (length arguments))
              span))
      (when (ormap named-arg? arguments)
        (bail 'CHECK-ENUM-POSITIONAL-ARGS "enum variants use positional arguments" span))
      (define substitutions (make-hash))
      (when (and (enum-type? expected)
                 (equal? (cadr expected) enum-name)
                 (= (length parameters) (length (cddr expected))))
        (for ([parameter (in-list parameters)] [argument-type (in-list (cddr expected))])
          (hash-set! substitutions parameter argument-type)))
      (for ([template (in-list payload-types)] [argument (in-list arguments)])
        (define context (substitute-type template substitutions))
        (when (and (has-type-variables? context)
                   (or (and (list-lit? argument) (null? (list-lit-elements argument)))
                       (and (map-lit? argument) (null? (map-lit-entries argument)))))
          (bail 'CHECK-ENUM-TYPE-INFERENCE
                "cannot infer enum type arguments from an empty collection payload"
                (node-span argument)))
        (define argument-type
          (check-expression argument (and (not (has-type-variables? context)) context)))
        (unify-type! template argument-type substitutions (node-span argument)))
      (define unresolved
        (filter (lambda (parameter) (not (hash-has-key? substitutions parameter))) parameters))
      (when (pair? unresolved)
        (bail 'CHECK-ENUM-TYPE-INFERENCE
              (format "cannot infer enum type parameter(s) ~a for ~a.~a"
                      (string-join unresolved ", ") (display-name enum-name) variant-name)
              span))
      (define result-type
        (cons 'Enum (cons enum-name (map (lambda (parameter)
                                           (hash-ref substitutions parameter))
                                         parameters))))
      (ensure result-type expected span))

    (define (check-construct expression expected)
      (define parts (string-split (construct-type-name expression) "."))
      (if (and (= (length parts) 2) (hash-has-key? enums (car parts)))
          (check-enum-constructor (car parts) (cadr parts) (construct-args expression)
                                  (construct-span expression) expected)
          (check-struct-construct expression)))

    (define (check-struct-construct expression)
      (define name (construct-type-name expression))
      (unless (hash-has-key? structs name)
        (bail 'CHECK-UNKNOWN-TYPE
              (format "\"~a\" is not a declared struct" (display-name name))
              (construct-span expression)
              #:help (did-you-mean name (hash-keys structs))))
      (define fields (hash-ref structs name))
      (define seen '())
      (for ([argument (in-list (construct-args expression))])
        (define field-name (named-arg-name argument))
        (define field (assoc field-name fields))
        (unless field
          (bail 'CHECK-UNKNOWN-FIELD
                (format "\"~a\" has no field \"~a\"" (display-name name) field-name)
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
                (format "constructor \"~a\" is missing field \"~a\"" (display-name name) (car field))
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
           (bail 'CHECK-EMPTY-MAP-TYPE
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

    (define (receiver-method-names kind target)
      (remove-duplicates
       (append (method-names kind) (if (printable-type? target) '("to_s" "inspect") '()))))

    (define (check-method expression target-node name arguments span expected record!
                          #:target-type [known #f])
      (define target (or known (check-expression target-node #f)))
      (define kind (receiver-kind target))
      (define resolved-name (or (and kind (resolve-method kind name))
                                (and (member name '("to_s" "inspect")) (printable-type? target)
                                     (if (equal? name "to_s") 'text 'inspect))))
      (unless resolved-name
        (bail 'CHECK-UNKNOWN-METHOD
              (format "~a has no method \"~a\"" (type->string target) name)
              span
              #:help (cond
                       [(member name '("to_s" "inspect"))
                        "only data values have to_s and inspect: numbers, Bool, String, nil, Json, ranges, and lists, maps, Results, structs and enums of those"]
                       [(and (struct-type? target) (hash-ref functions name #f))
                        (format "structs have no methods; call ~a(...) with the struct as an argument" name)]
                       [(and (struct-type? target)
                             (let ([field (assoc name (hash-ref structs (cadr target)))])
                               (and field (pair? (cdr field)) (eq? (car (cdr field)) 'Fn))))
                        (format "~a is a function field; call it with .~a.call(...)" name name)]
                       [(struct-type? target)
                        (format "structs have no methods; ~a"
                                (field-help name (hash-ref structs (cadr target))))]
                       [kind (or (foreign-method-help kind name)
                                 (did-you-mean name (receiver-method-names kind target))
                                 (format "~a methods: ~a" (type->string target)
                                         (string-join (sort (receiver-method-names kind target) string<?) ", ")))]
                       [(printable-type? target) (did-you-mean name '("to_s" "inspect"))]
                       [else #f])))
      (define receiver (typed-target target-node target))
      (cond
        [(eq? resolved-name 'self)
         (unless (null? arguments)
           (bail 'CHECK-ARITY (format "\"~a\" takes no arguments" name) span))
         (record! receiver)
         (ensure target expected span)]
        [(eq? resolved-name 'text)
         (unless (null? arguments)
           (bail 'CHECK-ARITY (format "\"~a\" takes no arguments" name) span))
         (record! (interpolation (list receiver) span))
         (ensure 'String expected span)]
        [(eq? resolved-name 'inspect)
         (unless (null? arguments)
           (bail 'CHECK-ARITY (format "\"~a\" takes no arguments" name) span))
         (record! (inspection receiver span))
         (ensure 'String expected span)]
        [else
         (define synthetic (call resolved-name (cons receiver arguments) span))
         (record! synthetic)
         (check-call synthetic expected)]))

    (define (check-block-lit block expected)
      (cond
        [(and expected (not (and (pair? expected) (eq? (car expected) 'Fn))))
         (bail 'CHECK-BLOCK-TARGET
               (format "a block is passed where ~a is expected" (type->string expected))
               (block-lit-span block)
               #:help "a block is only allowed when the last parameter is a function (Fn[...])")]
        [expected (check-block-body block (drop-right (cdr expected) 1) (last expected))]
        [else (check-block-body block #f #f)]))

    (define (check-block-body block known-parameters known-result)
      (define parameters (block-lit-params block))
      (when (and known-parameters (not (= (length known-parameters) (length parameters))))
        (bail 'CHECK-ARITY
              (format "this block takes ~a parameter(s), found ~a"
                      (length known-parameters) (length parameters))
              (block-lit-span block)))
      (define parameter-types
        (for/list ([parameter (in-list parameters)] [index (in-naturals)])
          (define annotated (and (block-param-type parameter)
                                 (resolve-type (block-param-type parameter))))
          (define known (and known-parameters (list-ref known-parameters index)))
          (cond
            [(and annotated known)
             (unless (equal? annotated known)
               (mismatch! known annotated (block-param-span parameter)))
             known]
            [(or annotated known)]
            [else
             (bail 'CHECK-BLOCK-TYPE
                   (format "the type of block parameter \"~a\" is not known here" (block-param-name parameter))
                   (block-param-span parameter)
                   #:help (format "annotate it, as in do |~a: Int| ... end" (block-param-name parameter)))])))
      (define saved-result current-result)
      (define saved-boundary capture-boundary)
      (define saved-loop-depth loop-depth)
      (set! loop-depth 0)
      (set! current-result (or known-result 'infer))
      (set! capture-boundary (length scopes))
      (push-scope!)
      (for ([parameter (in-list parameters)] [type (in-list parameter-types)])
        (introduce! (block-param-name parameter) type (block-param-span parameter)))
      (define statements (block-lit-body block))
      (define last-type
        (cond
          [(null? statements) #f]
          [else
           (for ([statement (in-list (drop-right statements 1))])
             (check-statement statement))
           (define final (last statements))
           (cond
             [(expr-stmt? final)
              (define value (expr-stmt-value final))
              (cond
                [(eq? current-result 'Void)
                 (check-unused-value! value (check-expression value #f #:completion? #t))
                 #f]
                [(eq? current-result 'infer) (check-expression value #f #:completion? #t)]
                [else (check-expression value current-result)])]
             [else (check-statement final) #f])]))
      (pop-scope!)
      (define result
        (cond
          [(not (eq? current-result 'infer)) current-result]
          [last-type]
          [else 'Void]))
      (set! current-result saved-result)
      (set! capture-boundary saved-boundary)
      (set! loop-depth saved-loop-depth)
      (when (and (not (eq? result 'Void))
                 (not last-type)
                 (not (block-returns? statements)))
        (bail 'CHECK-MISSING-RETURN
              (format "this block must give ~a on every path" (type->string result))
              (block-lit-span block)
              #:help "end the block with an expression, or return a value on every path"))
      (define block-type (cons 'Fn (append parameter-types (list result))))
      (when types (hash-set! types block block-type))
      block-type)

    (define (check-field-access expression expected)
      (define target (check-expression (field-access-target expression) #f))
      (cond
        [(and (struct-type? target)
              (not (and (member (field-access-name expression) '("to_s" "inspect"))
                        (not (assoc (field-access-name expression) (hash-ref structs (cadr target)))))))
         (check-struct-field expression target)]
        [else
         (check-method expression (field-access-target expression) (field-access-name expression)
                       '() (field-access-span expression) expected
                       (lambda (resolved) (set-field-access-resolved! expression resolved))
                       #:target-type target)]))

    (define (check-struct-field expression target)
      (define field (assoc (field-access-name expression) (hash-ref structs (cadr target))))
      (unless field
        (bail 'CHECK-UNKNOWN-FIELD
              (format "\"~a\" has no field \"~a\"" (display-name (cadr target)) (field-access-name expression))
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

    (define (check-case statement)
      (define value-type (check-expression (case-stmt-value statement) #f))
      (define result? (result-type? value-type))
      (define enum-definition
        (and (enum-type? value-type) (hash-ref enums (cadr value-type) #f)))
      (define variant-names
        (cond
          [result? '("Ok" "Err")]
          [enum-definition (hash-keys (cdr enum-definition))]
          [else #f]))
      (define covered-variants '())
      (define seen-literals '())
      (define wildcard? #f)
      (for ([arm (in-list (case-stmt-arms statement))])
        (when (or wildcard?
                  (and variant-names
                       (andmap (lambda (name) (member name covered-variants)) variant-names)))
          (bail 'CHECK-UNREACHABLE-CASE-ARM "case arm is unreachable" (node-span arm)))
        (define pattern (case-arm-pattern arm))
        (cond
          [(wildcard-pattern? pattern) (set! wildcard? #t)]
          [(literal-pattern? pattern)
           (define value (literal-pattern-value pattern))
           (define pattern-type (literal-type value))
           (unless (and (primitive-type? value-type) (eq? value-type pattern-type))
             (bail 'CHECK-PATTERN-TYPE
                   (format "literal pattern has type ~a, but case value has type ~a"
                           (type->string pattern-type) (type->string value-type))
                   (node-span pattern)))
           (when (member value seen-literals equal?)
             (bail 'CHECK-UNREACHABLE-CASE-ARM "duplicate literal case arm" (node-span arm)))
           (set! seen-literals (cons value seen-literals))]
          [(variant-pattern? pattern)
           (define enum-name (variant-pattern-enum-name pattern))
           (define variant-name (variant-pattern-variant-name pattern))
           (define payload-types
             (cond
               [(and result? (equal? enum-name "Result") (equal? variant-name "Ok"))
                (list (cadr value-type))]
               [(and result? (equal? enum-name "Result") (equal? variant-name "Err"))
                (list 'String)]
               [(and enum-definition (equal? enum-name (cadr value-type)))
                (define substitutions (make-hash))
                (for ([parameter (in-list (car enum-definition))]
                      [argument-type (in-list (cddr value-type))])
                  (hash-set! substitutions parameter argument-type))
                (define templates (hash-ref (cdr enum-definition) variant-name #f))
                (and templates
                     (map (lambda (template) (substitute-type template substitutions)) templates))]
               [else #f]))
           (unless payload-types
             (if (and enum-definition (equal? enum-name (cadr value-type)))
                 (bail 'CHECK-UNKNOWN-VARIANT
                       (format "enum \"~a\" has no variant \"~a\"" (display-name enum-name) variant-name)
                       (node-span pattern))
                 (bail 'CHECK-PATTERN-TYPE
                       (format "variant pattern \"~a.~a\" does not match ~a"
                               (display-name enum-name) variant-name (type->string value-type))
                       (node-span pattern))))
           (when (member variant-name covered-variants)
             (bail 'CHECK-UNREACHABLE-CASE-ARM "duplicate enum variant arm" (node-span arm)))
           (unless (= (length (variant-pattern-bindings pattern)) (length payload-types))
             (bail 'CHECK-ARITY
                   (format "variant pattern expects ~a binding(s), found ~a"
                           (length payload-types) (length (variant-pattern-bindings pattern)))
                   (node-span pattern)))
           (set! covered-variants (cons variant-name covered-variants))
           (push-scope!)
           (for ([binding-name (in-list (variant-pattern-bindings pattern))]
                 [binding-type (in-list payload-types)])
             (when (and binding-name (eq? binding-type 'Void))
               (bail 'CHECK-VOID-TYPE "a Void payload must be discarded with _" (node-span pattern)))
             (when binding-name (introduce! binding-name binding-type (node-span pattern))))
           (check-block (case-arm-body arm))
           (pop-scope!)])
        (unless (variant-pattern? pattern)
          (push-scope!)
          (check-block (case-arm-body arm))
          (pop-scope!)))
      (unless wildcard?
        (if variant-names
            (unless (andmap (lambda (name) (member name covered-variants)) variant-names)
              (bail 'CHECK-NON-EXHAUSTIVE-CASE
                    (format "case must cover every variant of ~a or include _" (type->string value-type))
                    (case-stmt-span statement)))
            (bail 'CHECK-NON-EXHAUSTIVE-CASE
                  "case on a non-enum value requires a final _ arm"
                  (case-stmt-span statement)))))

    (define (check-block statements)
      (for ([statement (in-list statements)])
        (check-statement statement)))

    (define (check-statement statement)
      (cond
        [(binding? statement) (check-binding statement)]
        [(return-stmt? statement) (check-return statement)]
        [(expr-stmt? statement)
         (define value (expr-stmt-value statement))
         (define type (check-expression value #f #:completion? #t))
         (check-unused-value! value type)]
        [(if-stmt? statement) (check-if statement)]
        [(case-stmt? statement) (check-case statement)]
        [(while-stmt? statement) (check-while statement)]
        [(for-stmt? statement) (check-for statement)]
        [(loop-control? statement)
         (when (zero? loop-depth)
           (bail 'CHECK-LOOP-CONTROL
                 (format "~a is only valid inside while or for" (loop-control-kind statement))
                 (loop-control-span statement)
                 #:help (if capture-boundary
                            "inside a block, return leaves the block (Ruby's next); a block cannot break its caller's loop"
                            "use it inside while or for; a function cannot break its caller's loop, so return a value and test it there")))]
        [else (bail 'CHECK-INTERNAL "unsupported statement" (node-span statement))]))

    (define (check-unused-value! value type)
      (define resolved
        (cond
          [(method-call? value) (method-call-resolved value)]
          [(field-access? value) (field-access-resolved value)]
          [else value]))
      (define entry (and (call? resolved) (builtin-ref (call-name resolved))))
      (when (and (not (eq? type 'Void))
                 (or (typed-target? resolved)
                     (and (not (eq? resolved value)) (or (interpolation? resolved) (inspection? resolved)))
                     (and entry
                          (null? (builtin-effects entry))
                          (not (takes-function? entry))
                          (not (string-suffix? (call-name resolved) "!")))))
        (bail 'CHECK-UNUSED-VALUE
              (format "the result of ~a is not used"
                      (if (call? resolved) (call-name resolved) "this expression"))
              (node-span value)
              #:help (let ([target (cond [(method-call? value) (method-call-target value)]
                                         [(field-access? value) (field-access-target value)]
                                         [(and (call? value) (pair? (call-args value))) (car (call-args value))]
                                         [else #f])])
                       (if (and (name-ref? target)
                                (or (typed-target? resolved) (keeps-first-type? entry)))
                           (format "values are immutable, so this call changes nothing; assign the result, for example ~a = ..."
                                   (name-ref-name target))
                           "values are immutable, so this call changes nothing; assign or use the result")))))

    (define (check-binding statement)
      (define name (binding-name statement))
      (reserve-local! name (binding-span statement))
      (define annotation (binding-type statement))
      (define declared (and annotation (resolve-type annotation)))
      (define existing (lookup name))
      (cond
        [existing
         (when (and capture-boundary
                    (>= (for/first ([frame (in-list scopes)] [index (in-naturals)]
                                    #:when (hash-has-key? frame name))
                          index)
                        (- (length scopes) capture-boundary)))
           (bail 'CHECK-CAPTURED-ASSIGNMENT
                 (format "a block cannot assign to \"~a\", which belongs to the enclosing code" name)
                 (binding-span statement)
                 #:help "blocks capture values; build the result with map or reduce, or use a for loop"))
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
      (cond
        [(eq? current-result 'infer)
         (set! current-result (if value (check-expression value #f #:completion? #t) 'Void))]
        [value
         (check-expression value current-result #:completion? (eq? current-result 'Void))]
        [else (ensure 'Void current-result (return-stmt-span statement))]))

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
      (in-loop (lambda () (check-block (while-stmt-body statement))))
      (pop-scope!))

    (define (in-loop thunk)
      (set! loop-depth (add1 loop-depth))
      (thunk)
      (set! loop-depth (sub1 loop-depth)))

    (define (check-for statement)
      (define iterable (check-expression (for-stmt-iterable statement) #f))
      (unless (or (list-type? iterable) (eq? iterable 'Range))
        (bail 'CHECK-NOT-A-LIST
              (format "\"for\" iterates over a list or a range, found ~a" (type->string iterable))
              (for-stmt-span statement)))
      (push-scope!)
      (introduce! (for-stmt-var statement) (if (eq? iterable 'Range) 'Int (cadr iterable))
                  (for-stmt-span statement) #t)
      (in-loop (lambda () (check-block (for-stmt-body statement))))
      (pop-scope!))

    (define (check-function declaration)
      (define result-type (resolve-type (function-decl-result declaration) #t))
      (set! loop-depth 0)
      (set! current-result result-type)
      (set! current-signature
            (format "~a(~a) -> ~a"
                    (display-name (function-decl-name declaration))
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
      (when (and (not (eq? result-type 'Void))
                 (not (block-returns? (function-decl-body declaration))))
        (bail 'CHECK-MISSING-RETURN
              (format "function \"~a\" must return ~a on every path"
                      (display-name (function-decl-name declaration)) (type->string result-type))
              (function-decl-span declaration)
              #:help (missing-return-help (function-decl-body declaration) (type->string result-type)))))

    ;; Program --------------------------------------------------------------

    (for ([declaration (in-list (program-declarations program))])
      (when (or (import-decl? declaration) (export-decl? declaration))
        (bail 'CHECK-MODULE-CONTEXT "resolve modules before checking" (node-span declaration))))
    (register-enum-names!)
    (register-structs!)
    (register-enum-variants!)
    (register-functions!)
    (check-main!)
    (for ([declaration (in-list (program-declarations program))])
      (when (function-decl? declaration)
        (check-function declaration)))
    program))
