#lang racket

(require "ast.rkt" "builtins.rkt" "diagnostic.rkt" "source.rkt")

(provide lower
         format-ir
         (struct-out ir-program)
         (struct-out ir-struct)
         (struct-out ir-enum)
         (struct-out ir-function)
         (struct-out ir-label)
         (struct-out ir-instr))

(struct ir-program (sources structs enums functions entry span) #:transparent)
(struct ir-struct (name fields) #:transparent)
(struct ir-enum (name variants) #:transparent)
(struct ir-function (name params slots body span) #:transparent)
(struct ir-label (id) #:transparent)
(struct ir-instr (op args spans) #:transparent)

(define int-min (- (expt 2 63)))
(define int-max (sub1 (expt 2 63)))

(define value-types '(Int Float Bool Nil String))

(define max-list-chunk 255)

(define (vm-type? type user-types)
  (cond
    [(list-type? type) (vm-type? (cadr type) user-types)]
    [(and (pair? type) (memq (car type) '(Struct Enum)))
     (eq? (hash-ref user-types (cadr type) #f) (car type))]
    [else (and (memq type value-types) #t)]))

(define (user-tables declarations)
  (values
   (for/list ([declaration (in-list declarations)] #:when (struct-decl? declaration))
     (ir-struct (struct-decl-name declaration) (map field-decl-name (struct-decl-fields declaration))))
   (for/list ([declaration (in-list declarations)] #:when (enum-decl? declaration))
     (ir-enum (enum-decl-name declaration)
              (for/list ([variant (in-list (enum-decl-variants declaration))])
                (cons (enum-variant-name variant) (length (enum-variant-payload-types variant))))))))

(define (list-type? type)
  (and (pair? type) (eq? (car type) 'List)))

(define int-ops
  (hasheq 'plus 'add-i 'minus 'sub-i 'multiply 'mul-i 'divide 'div-i 'modulo 'mod-i
          'less 'lt-i 'less-equal 'le-i 'greater 'lt-i 'greater-equal 'le-i))

(define float-ops
  (hasheq 'plus 'add-f 'minus 'sub-f 'multiply 'mul-f 'divide 'div-f
          'less 'lt-f 'less-equal 'le-f 'greater 'lt-f 'greater-equal 'le-f))

(define string-ops (hasheq 'plus 'concat))

(define vm-builtins '("puts" "IO.print" "IO.warn" "String.from_int" "String.from_float"))

(define (lower program types)
  (let/ec return
    (define (unsupported what span)
      (return (diagnostic 'LOWER-UNSUPPORTED
                          (format "the VM does not support ~a yet" what)
                          span)))
    (with-handlers ([exn:fail? (lambda (failure)
                                 (diagnostic 'LOWER-INTERNAL (exn-message failure)
                                             (program-span program)))])
      (define declarations
        (for/list ([declaration (in-list (program-declarations program))]
                   #:when (function-decl? declaration))
          declaration))
      (define-values (structs enums) (user-tables (program-declarations program)))
      (define user-types (make-hash))
      (define struct-info (make-hash))
      (for ([entry (in-list structs)] [index (in-naturals)])
        (hash-set! user-types (ir-struct-name entry) 'Struct)
        (hash-set! struct-info (ir-struct-name entry) (cons index (ir-struct-fields entry))))
      (define variant-ids (make-hash))
      (for/fold ([id 0]) ([entry (in-list enums)])
        (hash-set! user-types (ir-enum-name entry) 'Enum)
        (for/fold ([id id]) ([variant (in-list (ir-enum-variants entry))])
          (hash-set! variant-ids (cons (ir-enum-name entry) (car variant)) id)
          (add1 id)))
      (define program-types (list user-types struct-info variant-ids))
      (define function-index
        (for/hash ([declaration (in-list declarations)] [index (in-naturals)])
          (values (function-decl-name declaration) index)))
      (define sources '())
      (define (note-source! span)
        (define text-source (source-span-source span))
        (unless (memq text-source sources)
          (set! sources (append sources (list text-source)))))
      (note-source! (program-span program))
      (define functions
        (for/list ([declaration (in-list declarations)])
          (lower-function declaration types program-types function-index unsupported note-source!)))
      (ir-program sources structs enums functions (hash-ref function-index "main")
                  (program-span program)))))

(define (lower-function declaration types program-types function-index unsupported note-source!)
  (match-define (list user-types struct-info variant-ids) program-types)
  (define code '())
  (define next 0)
  (define high 0)
  (define scopes (list (make-hash)))
  (define label-count 0)
  (define loop-labels #f)
  (define after-step #f)

  (define (emit! op args . spans)
    (for-each note-source! spans)
    (set! code (cons (ir-instr op args spans) code)))
  (define (new-label!)
    (set! label-count (add1 label-count))
    (sub1 label-count))
  (define (place! label) (set! code (cons (ir-label label) code)))
  (define (alloc!)
    (define slot next)
    (set! next (add1 next))
    (set! high (max high next))
    slot)
  (define (lookup name)
    (for/or ([scope (in-list scopes)]) (hash-ref scope name #f)))
  (define (scoped thunk)
    (define saved next)
    (set! scopes (cons (make-hash) scopes))
    (thunk)
    (set! scopes (cdr scopes))
    (set! next saved))

  (define (type-of expression)
    (hash-ref types expression #f))
  (define (require-type! expression void? [type (type-of expression)])
    (unless (or (vm-type? type user-types) (and void? (eq? type 'Void)))
      (unsupported (if type (format "values of type ~a" (type->string type)) "this expression")
                   (node-span expression))))

  (define (target want)
    (or want (alloc!)))
  (define (resolved-of expression)
    (cond
      [(method-call? expression) (method-call-resolved expression)]
      [(field-access? expression) (field-access-resolved expression)]
      [else #f]))
  (define (static-type expression)
    (if (typed-target? expression) (typed-target-type expression) (type-of expression)))

  (define (lower-expression expression want #:void? [void? #f] #:known? [known? #f])
    (cond
      [(and (unary? expression) (eq? (unary-op expression) 'minus)
            (literal? (unary-operand expression))
            (eqv? (literal-value (unary-operand expression)) (- int-min)))
       (emit! 'step '() (unary-span expression))
       (emit! 'step '() (literal-span (unary-operand expression)))
       (define dst (target want))
       (emit! 'const (list dst int-min) (unary-span expression))
       dst]
      [(call? expression) (lower-call expression want void?)]
      [(resolved-of expression)
       => (lambda (resolved)
            (require-type! expression void?)
            (if (call? resolved)
                (lower-call resolved want void? #:checked? #t)
                (lower-expression resolved want)))]
      [(typed-target? expression)
       (define inner (typed-target-expression expression))
       (require-type! inner #f (typed-target-type expression))
       (lower-expression inner want)]
      [(or (interpolation? expression) (inspection? expression)) (lower-value expression want)]
      [else
       (unless known? (require-type! expression #f))
       (lower-value expression want)]))

  (define (lower-value expression want)
    (define span (node-span expression))
    (cond
      [(literal? expression)
       (emit! 'step '() span)
       (define dst (target want))
       (emit! 'const (list dst (literal-value expression)) span)
       dst]
      [(name-ref? expression)
       (emit! 'step '() span)
       (define slot (lookup (name-ref-name expression)))
       (cond
         [want (emit! 'move (list want slot) span) want]
         [else slot])]
      [(unary? expression)
       (emit! 'step '() span)
       (define saved next)
       (define dst (target want))
       (define operand (lower-expression (unary-operand expression) #f))
       (emit! (cond [(eq? (unary-op expression) 'not) 'not]
                    [(eq? (type-of (unary-operand expression)) 'Float) 'neg-f]
                    [else 'neg-i])
              (list dst operand)
              (unary-op-span expression))
       (set! next (if want saved (add1 dst)))
       dst]
      [(binary? expression) (lower-binary expression want)]
      [(list-lit? expression) (lower-list expression want)]
      [(enum-constructor? expression)
       (lower-enum (enum-constructor-enum-name expression) (enum-constructor-variant-name expression)
                   (enum-constructor-args expression) span want)]
      [(construct? expression)
       (define parts (string-split (construct-type-name expression) "."))
       (if (and (= (length parts) 2) (eq? (hash-ref user-types (car parts) #f) 'Enum))
           (lower-enum (car parts) (cadr parts)
                       (for/list ([argument (in-list (construct-args expression))])
                         (if (named-arg? argument) (named-arg-value argument) argument))
                       span want)
           (lower-struct expression want))]
      [(field-access? expression)
       (emit! 'step '() span)
       (define saved next)
       (define dst (target want))
       (define target-node (field-access-target expression))
       (define source (lower-expression target-node #f))
       (define fields (cdr (hash-ref struct-info (cadr (static-type target-node)))))
       (emit! 'field (list dst source (index-of fields (field-access-name expression))) span)
       (set! next (if want saved (add1 dst)))
       dst]
      [(index-access? expression)
       (define target-node (index-access-target expression))
       (unless (list-type? (static-type target-node))
         (unsupported "indexing a map" span))
       (emit! 'step '() span)
       (define saved next)
       (define dst (target want))
       (define items (lower-expression target-node #f))
       (define index (lower-expression (index-access-index expression) #f))
       (emit! 'list-get (list dst items index) (node-span (index-access-index expression)))
       (set! next (if want saved (add1 dst)))
       dst]
      [(inspection? expression)
       (emit! 'step '() span)
       (define saved next)
       (define dst (target want))
       (define operand (lower-expression (inspection-target expression) #f))
       (emit! 'inspect (list dst operand) span)
       (set! next (if want saved (add1 dst)))
       dst]
      [(interpolation? expression)
       (emit! 'step '() span)
       (define saved next)
       (define dst (target want))
       (define parts (interpolation-parts expression))
       (define (lower-part! part slot)
         (cond
           [(string? part) (emit! 'const (list slot part) span)]
           [else
            (lower-expression part slot)
            (unless (eq? (static-type part) 'String)
              (emit! 'to-text (list slot slot) span))]))
       (cond
         [(null? parts) (emit! 'const (list dst "") span)]
         [else
          (lower-part! (car parts) dst)
          (for ([part (in-list (cdr parts))])
            (define slot (alloc!))
            (lower-part! part slot)
            (emit! 'concat (list dst dst slot) span)
            (set! next slot))])
       (set! next (if want saved (add1 dst)))
       dst]
      [else (unsupported "this expression" span)]))

  (define (lower-list expression want)
    (define span (list-lit-span expression))
    (emit! 'step '() span)
    (define saved next)
    (define elements (list-lit-elements expression))
    (define (lower-elements! items)
      (define start next)
      (for ([element (in-list items)])
        (lower-expression element (alloc!) #:known? #t))
      start)
    (define dst
      (cond
        [(<= (length elements) max-list-chunk)
         (define dst (target want))
         (define start (lower-elements! elements))
         (emit! 'list (list dst (if (null? elements) dst start) (length elements)) span)
         dst]
        [else
         (define base (alloc!))
         (let loop ([items elements] [first? #t])
           (define-values (chunk rest)
             (if (> (length items) max-list-chunk)
                 (split-at items max-list-chunk)
                 (values items '())))
           (set! next (add1 base))
           (define start (lower-elements! chunk))
           (cond
             [first? (emit! 'list (list base start (length chunk)) span)]
             [else
              (emit! 'list (list start start (length chunk)) span)
              (emit! 'call-builtin (list base "List.concat" 2) span span span)])
           (unless (null? rest) (loop rest #f)))
         (cond
           [want (emit! 'move (list want base) span) want]
           [else base])]))
    (set! next (if want saved (add1 dst)))
    dst)

  (define (lower-enum enum-name variant-name arguments span want)
    (emit! 'step '() span)
    (define saved next)
    (define dst (target want))
    (define id (hash-ref variant-ids (cons enum-name variant-name)))
    (define start next)
    (for ([argument (in-list arguments)])
      (lower-expression argument (alloc!)))
    (emit! 'enum (list dst (if (null? arguments) dst start) id) span)
    (set! next (if want saved (add1 dst)))
    dst)

  (define (lower-struct expression want)
    (define span (construct-span expression))
    (match-define (cons index fields) (hash-ref struct-info (construct-type-name expression)))
    (emit! 'step '() span)
    (define saved next)
    (define dst (target want))
    (define start next)
    (for ([_ (in-list fields)]) (alloc!))
    (define after next)
    (for ([argument (in-list (construct-args expression))])
      (lower-expression (named-arg-value argument)
                        (+ start (index-of fields (named-arg-name argument))))
      (set! next after))
    (emit! 'struct (list dst (if (null? fields) dst start) index) span)
    (set! next (if want saved (add1 dst)))
    dst)

  (define (lower-binary expression want)
    (emit! 'step '() (binary-span expression))
    (define op (binary-op expression))
    (define op-span (binary-op-span expression))
    (define saved next)
    (define dst (target want))
    (cond
      [(memq op '(and or))
       (define end (new-label!))
       (lower-expression (binary-left expression) dst)
       (emit! (if (eq? op 'and) 'jump-if-false 'jump-if-true) (list dst end) op-span)
       (lower-expression (binary-right expression) dst)
       (place! end)]
      [else
       (define ops (case (type-of (binary-left expression))
                     [(Float) float-ops]
                     [(String) string-ops]
                     [else int-ops]))
       (define left (lower-expression (binary-left expression) #f))
       (define right (lower-expression (binary-right expression) #f))
       (case op
         [(equal not-equal)
          (emit! (if (eq? op 'equal) 'eq 'ne) (list dst left right) op-span)]
         [(greater greater-equal)
          (emit! (hash-ref ops op) (list dst right left) op-span)]
         [else (emit! (hash-ref ops op) (list dst left right) op-span)])])
    (set! next (if want saved (add1 dst)))
    dst)

  (define (lower-call expression want void? #:checked? [checked? #f])
    (define name (call-name expression))
    (define arguments (call-args expression))
    (define span (call-span expression))
    (define entry (builtin-ref name (length arguments)))
    (define key (and entry (builtin-implementation entry)))
    (define builtin? (and key (member key vm-builtins) #t))
    (when (and entry (not builtin?))
      (unsupported (format "the builtin ~a" name) span))
    (unless (or builtin? (hash-has-key? function-index name))
      (unsupported (format "the call to ~a" name) span))
    (unless checked?
      (require-type! expression void?))
    (emit! 'step '() span)
    (define saved next)
    (define base (alloc!))
    (for ([argument (in-list arguments)] [index (in-naturals)])
      (set! next (+ base index))
      (define slot (alloc!))
      (lower-expression argument slot))
    (if builtin?
        (apply emit! 'call-builtin (list base key (length arguments)) span (map node-span arguments))
        (emit! 'call (list base (hash-ref function-index name)) span))
    (cond
      [want (emit! 'move (list want base) span)
            (set! next saved)
            want]
      [else (set! next (add1 base)) base]))

  (define (lower-block statements)
    (for ([statement (in-list statements)])
      (lower-statement statement)))

  (define (lower-statement statement)
    (define span (node-span statement))
    (define saved next)
    (emit! 'step '() span)
    (when after-step
      (define hook after-step)
      (set! after-step #f)
      (hook))
    (cond
      [(binding? statement)
       (define name (binding-name statement))
       (define existing (lookup name))
       (cond
         [existing
          (define slot (lower-expression (binding-value statement) #f))
          (unless (= slot existing)
            (emit! 'move (list existing slot) span))
          (set! next saved)]
         [else
          (define slot (alloc!))
          (lower-expression (binding-value statement) slot)
          (hash-set! (car scopes) name slot)])]
      [(return-stmt? statement)
       (define value (return-stmt-value statement))
       (define slot
         (cond
           [value (lower-expression value #f #:void? #t)]
           [else (define slot (alloc!)) (emit! 'const (list slot (void)) span) slot]))
       (emit! 'return (list slot) span)
       (set! next saved)]
      [(expr-stmt? statement)
       (lower-expression (expr-stmt-value statement) #f #:void? #t)
       (set! next saved)]
      [(if-stmt? statement)
       (define end (new-label!))
       (define branches (if-stmt-branches statement))
       (define else-body (if-stmt-else-body statement))
       (for ([branch (in-list branches)] [index (in-naturals 1)])
         (define skip (new-label!))
         (define condition (lower-expression (if-branch-condition branch) #f))
         (emit! 'jump-if-false (list condition skip) (node-span (if-branch-condition branch)))
         (set! next saved)
         (scoped (lambda () (lower-block (if-branch-body branch))))
         (when (or else-body (< index (length branches)))
           (emit! 'jump (list end) span))
         (place! skip))
       (when else-body
         (scoped (lambda () (lower-block else-body))))
       (place! end)]
      [(while-stmt? statement)
       (define head (new-label!))
       (define exit (new-label!))
       (place! head)
       (define condition (lower-expression (while-stmt-condition statement) #f))
       (emit! 'jump-if-false (list condition exit) (node-span (while-stmt-condition statement)))
       (set! next saved)
       (define outer loop-labels)
       (set! loop-labels (cons head exit))
       (scoped (lambda () (lower-block (while-stmt-body statement))))
       (set! loop-labels outer)
       (emit! 'jump (list head) span)
       (place! exit)]
      [(and (loop-control? statement) loop-labels)
       (emit! 'jump (list (if (eq? (loop-control-kind statement) 'break)
                              (cdr loop-labels)
                              (car loop-labels)))
              span)]
      [(for-stmt? statement)
       (define body (for-stmt-body statement))
       (define items (alloc!))
       (lower-expression (for-stmt-iterable statement) items)
       (unless (null? body)
         (define index (alloc!))
         (define count (alloc!))
         (define temp (alloc!))
         (define one (alloc!))
         (define top (new-label!))
         (define increment (new-label!))
         (define test (new-label!))
         (define exit (new-label!))
         (emit! 'const (list index 0) span)
         (emit! 'list-len (list count items) span)
         (emit! 'const (list one 1) span)
         (emit! 'jump (list test) span)
         (define outer loop-labels)
         (set! loop-labels (cons increment exit))
         (scoped (lambda ()
                   (define element (alloc!))
                   (hash-set! (car scopes) (for-stmt-var statement) element)
                   (place! top)
                   (set! after-step (lambda () (emit! 'list-get (list element items index) span)))
                   (lower-block body)
                   (when after-step (error 'lower "for body did not read its element"))))
         (set! loop-labels outer)
         (place! increment)
         (emit! 'add-i (list index index one) span)
         (place! test)
         (emit! 'lt-i (list temp index count) span)
         (emit! 'jump-if-true (list temp top) span)
         (place! exit))
       (set! next saved)]
      [(case-stmt? statement)
       (define value (lower-expression (case-stmt-value statement) #f))
       (define end (new-label!))
       (define arms (case-stmt-arms statement))
       (for ([arm (in-list arms)] [index (in-naturals 1)])
         (define pattern (case-arm-pattern arm))
         (define pattern-span (node-span pattern))
         (define skip (new-label!))
         (define test-slot next)
         (cond
           [(wildcard-pattern? pattern) (void)]
           [(literal-pattern? pattern)
            (define literal (literal-pattern-value pattern))
            (cond
              [(and (exact-integer? literal) (not (<= int-min literal int-max)))
               (emit! 'jump (list skip) pattern-span)]
              [else
               (define slot (alloc!))
               (emit! 'const (list slot literal) pattern-span)
               (emit! 'same (list slot value slot) pattern-span)
               (emit! 'jump-if-false (list slot skip) pattern-span)])]
           [else
            (define id (hash-ref variant-ids (cons (variant-pattern-enum-name pattern)
                                                   (variant-pattern-variant-name pattern))))
            (define slot (alloc!))
            (emit! 'is-variant (list slot value id) pattern-span)
            (emit! 'jump-if-false (list slot skip) pattern-span)])
         (set! next test-slot)
         (scoped (lambda ()
                   (when (variant-pattern? pattern)
                     (for ([name (in-list (variant-pattern-bindings pattern))] [item (in-naturals)]
                           #:when name)
                       (define slot (alloc!))
                       (hash-set! (car scopes) name slot)
                       (emit! 'payload (list slot value item) pattern-span)))
                   (lower-block (case-arm-body arm))))
         (when (< index (length arms))
           (emit! 'jump (list end) span))
         (place! skip))
       (place! end)
       (set! next saved)]
      [else (unsupported "this statement" span)]))

  (for ([parameter (in-list (function-decl-params declaration))])
    (hash-set! (car scopes) (param-name parameter) (alloc!)))
  (define params next)
  (lower-block (function-decl-body declaration))
  (define void-slot (alloc!))
  (emit! 'const (list void-slot (void)) (function-decl-span declaration))
  (emit! 'return (list void-slot) (function-decl-span declaration))
  (ir-function (function-decl-name declaration) params high (reverse code)
               (function-decl-span declaration)))

(define (span-text span)
  (define start (source-span-start span))
  (format "~a:~a" (source-position-line start) (source-position-column start)))

(define (format-arg op index value)
  (cond
    [(and (eq? op 'const) (= index 1))
     (cond [(void? value) "void"] [else (format "~s" value)])]
    [(and (memq op '(jump jump-if-false jump-if-true))
          (= index (if (eq? op 'jump) 0 1)))
     (format "L~a" value)]
    [(and (eq? op 'call) (= index 1)) (format "fn~a" value)]
    [(and (memq op '(enum is-variant)) (= index 2)) (format "v~a" value)]
    [(and (eq? op 'struct) (= index 2)) (format "s~a" value)]
    [(and (memq op '(field payload)) (= index 2)) (format "~a" value)]
    [(and (eq? op 'list) (= index 2)) (format "~a" value)]
    [(and (eq? op 'call-builtin) (>= index 1)) (format "~a" value)]
    [else (format "r~a" value)]))

(define (format-tables ir)
  (define structs
    (for/list ([entry (in-list (ir-program-structs ir))] [index (in-naturals)])
      (format "struct s~a ~a~a" index (ir-struct-name entry)
              (string-append*
               (for/list ([field (in-list (ir-struct-fields entry))])
                 (format " ~a" field))))))
  (define enums
    (let loop ([entries (ir-program-enums ir)] [id 0] [out '()])
      (cond
        [(null? entries) (reverse out)]
        [else
         (define variants (ir-enum-variants (car entries)))
         (loop (cdr entries) (+ id (length variants))
               (cons (format "enum ~a~a" (ir-enum-name (car entries))
                             (string-append*
                              (for/list ([variant (in-list variants)] [k (in-naturals id)])
                                (format " v~a=~a/~a" k (car variant) (cdr variant)))))
                     out))])))
  (append structs enums))

(define (format-ir ir)
  (define tables (format-tables ir))
  (string-append
   (if (null? tables) "" (string-append (string-join tables "\n") "\n\n"))
   (format-functions ir)))

(define (format-functions ir)
  (string-join
   (for/list ([function (in-list (ir-program-functions ir))] [index (in-naturals)])
     (string-join
      (cons (format "fn~a ~a params=~a slots=~a~a" index (ir-function-name function)
                    (ir-function-params function) (ir-function-slots function)
                    (if (= index (ir-program-entry ir)) " entry" ""))
            (for/list ([item (in-list (ir-function-body function))])
              (cond
                [(ir-label? item) (format "  L~a:" (ir-label-id item))]
                [else
                 (define op (ir-instr-op item))
                 (format "    ~a~a  @ ~a" op
                         (string-append*
                          (for/list ([arg (in-list (ir-instr-args item))] [i (in-naturals)])
                            (string-append " " (format-arg op i arg))))
                         (string-join (map span-text (ir-instr-spans item)) " "))])))
      "\n"))
   "\n\n"))
