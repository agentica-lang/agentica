#lang racket

;; Module constants (docs/future/44-module-constants.md): the parts of the checker and the lowering that
;; read the tree the same way. A node's children come in source order, so the order of the constants
;; is the same everywhere (and in compiler/, which does the same on its own tree).

(require "ast.rkt" "builtins.rkt" "source.rkt")

(provide node-children
         constant-references
         constant-order
         cycle-text
         (struct-out constant-plan)
         plan-constants)

;; The expressions and statements directly below a node, in source order. Literals and names have none.
(define (node-children node)
  (match node
    [(call _ args _ _) args]
    [(enum-constructor _ _ args _) args]
    [(invoke target args _) (cons target args)]
    [(named-arg _ value _) (list value)]
    [(construct _ args _) args]
    [(struct-update target args _ _) (cons target args)]
    [(list-lit elements _) elements]
    [(map-entry key value _) (list key value)]
    [(map-lit entries _) entries]
    [(field-access target _ _ _) (list target)]
    [(method-call target _ args _ _) (cons target args)]
    [(interpolation parts _) (filter (lambda (part) (not (string? part))) parts)]
    [(inspection target _) (list target)]
    [(block-lit _ body _) body]
    [(index-access target index _) (list target index)]
    [(try-expr operand _) (list operand)]
    [(unary _ _ operand _) (list operand)]
    [(binary _ _ left right _) (list left right)]
    [(binding _ _ value _) (list value)]
    [(return-stmt value _) (if value (list value) '())]
    [(expr-stmt value _) (list value)]
    [(if-branch condition body _) (cons condition body)]
    [(if-stmt branches else-body _) (append branches (or else-body '()))]
    [(while-stmt condition body _) (cons condition body)]
    [(for-stmt _ iterable body _) (cons iterable body)]
    [(case-stmt value arms _) (cons value arms)]
    [(case-arm _ body _) body]
    [(typed-target expression _) (list expression)]
    [_ '()]))

(define (start-offset node)
  (source-position-offset (source-span-start (node-span node))))

;; The reads of constants below a node, ordered by the start offsets of the reads in the source text,
;; so the order does not depend on how a tree stores its parts (a map entry gives its key before its value).
(define (constant-references node)
  (define found '())
  (let walk ([node node])
    (when (const-ref? node) (set! found (cons node found)))
    (for-each walk (node-children node)))
  (sort (reverse found) < #:key start-offset))

;; The constants in initialization order, from declarations in linked order: to visit a constant, first
;; visit the constants its initializer reads, in the order of the reads, then emit it. The first read
;; that reaches a constant already on the path is a cycle. Returns (values order #f), or
;; (values #f (cons read names)) where read is the const-ref that closes the cycle and names the linked
;; names around it, starting and ending with the constant it reads.
(define (constant-order declarations)
  (define by-name (for/hash ([declaration (in-list declarations)]) (values (const-decl-name declaration) declaration)))
  (define state (make-hash))
  (define ordered '())
  (let/ec escape
    (define (visit declaration path)
      (define name (const-decl-name declaration))
      (hash-set! state name 'visiting)
      (for ([read (in-list (constant-references (const-decl-value declaration)))])
        (define target (const-ref-name read))
        (case (hash-ref state target #f)
          [(visiting)
           (define around (member target (reverse (cons name path))))
           (escape #f (cons read (append around (list target))))]
          [(done) (void)]
          [else (visit (hash-ref by-name target) (cons name path))]))
      (hash-set! state name 'done)
      (set! ordered (cons declaration ordered)))
    (for ([declaration (in-list declarations)])
      (unless (hash-ref state (const-decl-name declaration) #f)
        (visit declaration '())))
    (values (reverse ordered) #f)))

;; A -> B -> A, with the names as written.
(define (cycle-text names)
  (string-join (map display-name names) " -> "))

;; What the lowering does with the constants of a program (44.7, 44.8).
;; kept: the constants to initialize, in initialization order. slots: linked name -> slot, for every
;; non-literal constant that an emitted function reads, numbered in initialization order; its size is the
;; Globals count. literals: linked name -> value, for the constants with a scalar literal initializer,
;; which are inlined at each read and have no slot.
(struct constant-plan (kept slots literals) #:transparent)

;; The value of a scalar literal initializer (one literal, or `-` and a number literal) in a box, or #f.
(define (literal-value-box declaration)
  (define value (const-decl-value declaration))
  (cond
    [(literal? value) (box (literal-value value))]
    [(and (unary? value) (eq? (unary-op value) 'minus)
          (literal? (unary-operand value))
          (real? (literal-value (unary-operand value))))
     (box (- (literal-value (unary-operand value))))]
    [else #f]))

;; The names of the constants, the functions and the function references below a node, in the order found.
(define (names-below node)
  (define constants '())
  (define functions '())
  (let walk ([node node])
    (cond
      [(list? node) (for-each walk node)]
      [(const-ref? node) (set! constants (cons (const-ref-name node) constants))]
      [(call? node) (set! functions (cons (call-name node) functions))]
      [(function-ref? node) (set! functions (cons (function-ref-name node) functions))])
    (unless (list? node) (for-each walk (node-children node))))
  (values (reverse constants) (reverse functions)))

;; Decides which constants are initialized and which get a slot. The functions reachable from main (by
;; calls, `&f` and the blocks inside, to a fixed point) decide the kept constants, then the constants those
;; read; a slot is given to every non-literal constant that any emitted function reads, reachable or not,
;; so the code of an unreachable function still loads. `order` is the initialization order of the program's
;; constants; functions are the function-decls and constants the const-decls, in program order.
(define (plan-constants functions constants order)
  (define by-name (for/hash ([declaration (in-list constants)]) (values (const-decl-name declaration) declaration)))
  (define literals
    (for*/hash ([declaration (in-list constants)]
                [found (in-value (literal-value-box declaration))]
                #:when found)
      (values (const-decl-name declaration) (unbox found))))
  (define function-by-name
    (for/hash ([declaration (in-list functions)]) (values (function-decl-name declaration) declaration)))
  (define (reads-of declaration)
    (names-below (if (const-decl? declaration) (const-decl-value declaration) (function-decl-body declaration))))
  (define (non-literal names) (filter (lambda (name) (not (hash-has-key? literals name))) names))
  ;; The reachable functions.
  (define reached (make-hash))
  (define reached-reads '())
  (let loop ([pending (list "main")])
    (unless (null? pending)
      (define name (car pending))
      (cond
        [(or (hash-ref reached name #f) (not (hash-has-key? function-by-name name))) (loop (cdr pending))]
        [else
         (hash-set! reached name #t)
         (define-values (constant-names function-names) (reads-of (hash-ref function-by-name name)))
         (set! reached-reads (append (reverse constant-names) reached-reads))
         (loop (append function-names (cdr pending)))])))
  ;; The constants those functions keep, then the ones those constants read.
  (define kept-set (make-hash))
  (let loop ([pending (non-literal (reverse reached-reads))])
    (unless (null? pending)
      (define name (car pending))
      (cond
        [(hash-ref kept-set name #f) (loop (cdr pending))]
        [else
         (hash-set! kept-set name #t)
         (define-values (constant-names function-names) (reads-of (hash-ref by-name name)))
         (loop (append (non-literal constant-names) (cdr pending)))])))
  ;; Every function is emitted, so every constant any of them reads needs a slot.
  (define slot-set (make-hash))
  (for ([name (in-hash-keys kept-set)]) (hash-set! slot-set name #t))
  (for ([declaration (in-list functions)])
    (define-values (constant-names function-names) (reads-of declaration))
    (for ([name (in-list (non-literal constant-names))]) (hash-set! slot-set name #t)))
  (define kept (filter (lambda (declaration) (hash-ref kept-set (const-decl-name declaration) #f)) order))
  (define slots
    (for/hash ([declaration (in-list (filter (lambda (declaration) (hash-ref slot-set (const-decl-name declaration) #f)) order))]
               [index (in-naturals)])
      (values (const-decl-name declaration) index)))
  (constant-plan kept slots literals))
