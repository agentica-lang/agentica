#lang racket

;; Module constants (docs/future/44-module-constants.md): the parts of the checker and the lowering that
;; read the tree the same way. A node's children come in source order, so the order of the constants
;; is the same everywhere (and in compiler/, which does the same on its own tree).

(require "ast.rkt" "builtins.rkt" "source.rkt")

(provide node-children
         constant-references
         constant-order
         cycle-text)

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
