#lang racket

(require "source.rkt")

(provide (struct-out program)
         (struct-out function-decl)
         (struct-out param)
         (struct-out struct-decl)
         (struct-out field-decl)
         (struct-out type-ref)
         (struct-out type-expression)
         (struct-out binding)
         (struct-out return-stmt)
         (struct-out expr-stmt)
         (struct-out if-branch)
         (struct-out if-stmt)
         (struct-out while-stmt)
         (struct-out for-stmt)
         (struct-out literal)
         (struct-out name-ref)
         (struct-out call)
         (struct-out function-ref)
         (struct-out invoke)
         (struct-out named-arg)
         (struct-out construct)
         (struct-out list-lit)
         (struct-out map-entry)
         (struct-out map-lit)
         (struct-out field-access)
         (struct-out index-access)
         (struct-out try-expr)
         (struct-out unary)
         (struct-out binary)
         node-span)

(struct program (declarations span) #:transparent)
(struct function-decl (name params result body span) #:transparent)
(struct param (name type span) #:transparent)
(struct struct-decl (name fields span) #:transparent)
(struct field-decl (name type span) #:transparent)

(struct type-ref (name args span) #:transparent)
(struct type-expression (name span) #:transparent)

(struct binding (name type value span) #:transparent)
(struct return-stmt (value span) #:transparent)
(struct expr-stmt (value span) #:transparent)
(struct if-branch (condition body span) #:transparent)
(struct if-stmt (branches else-body span) #:transparent)
(struct while-stmt (condition body span) #:transparent)
(struct for-stmt (var iterable body span) #:transparent)

(struct literal (value span) #:transparent)
(struct name-ref (name span) #:transparent)
(struct call (name args span) #:transparent)
(struct function-ref (name span) #:transparent)
(struct invoke (target args span) #:transparent)
(struct named-arg (name value span) #:transparent)
(struct construct (type-name args span) #:transparent)
(struct list-lit (elements span) #:transparent)
(struct map-entry (key value span) #:transparent)
(struct map-lit (entries span) #:transparent)
(struct field-access (target name span) #:transparent)
(struct index-access (target index span) #:transparent)
(struct try-expr (operand span) #:transparent)
(struct unary (op op-span operand span) #:transparent)
(struct binary (op op-span left right span) #:transparent)

(define (node-span node)
  (cond
    [(program? node) (program-span node)]
    [(function-decl? node) (function-decl-span node)]
    [(param? node) (param-span node)]
    [(struct-decl? node) (struct-decl-span node)]
    [(field-decl? node) (field-decl-span node)]
    [(type-ref? node) (type-ref-span node)]
    [(type-expression? node) (type-expression-span node)]
    [(binding? node) (binding-span node)]
    [(return-stmt? node) (return-stmt-span node)]
    [(expr-stmt? node) (expr-stmt-span node)]
    [(if-branch? node) (if-branch-span node)]
    [(if-stmt? node) (if-stmt-span node)]
    [(while-stmt? node) (while-stmt-span node)]
    [(for-stmt? node) (for-stmt-span node)]
    [(literal? node) (literal-span node)]
    [(name-ref? node) (name-ref-span node)]
    [(call? node) (call-span node)]
    [(function-ref? node) (function-ref-span node)]
    [(invoke? node) (invoke-span node)]
    [(named-arg? node) (named-arg-span node)]
    [(construct? node) (construct-span node)]
    [(list-lit? node) (list-lit-span node)]
    [(map-entry? node) (map-entry-span node)]
    [(map-lit? node) (map-lit-span node)]
    [(field-access? node) (field-access-span node)]
    [(index-access? node) (index-access-span node)]
    [(try-expr? node) (try-expr-span node)]
    [(unary? node) (unary-span node)]
    [(binary? node) (binary-span node)]
    [else #f]))
