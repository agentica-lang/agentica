#lang racket

(require "source.rkt")

(provide (struct-out program)
         (struct-out import-decl)
         (struct-out export-decl)
         (struct-out function-decl)
         (struct-out param)
         (struct-out struct-decl)
         (struct-out enum-decl)
         (struct-out enum-variant)
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
         (struct-out case-stmt)
         (struct-out case-arm)
         (struct-out wildcard-pattern)
         (struct-out literal-pattern)
         (struct-out variant-pattern)
         (struct-out enum-constructor)
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
         (struct-out method-call)
         (struct-out typed-target)
         (struct-out interpolation)
         (struct-out block-lit)
         (struct-out block-param)
         (struct-out index-access)
         (struct-out try-expr)
         (struct-out unary)
         (struct-out binary)
         node-span)

(struct program (declarations span) #:transparent)
(struct import-decl (path alias span) #:transparent)
(struct export-decl (declaration span) #:transparent)
(struct function-decl (name params result body span) #:transparent)
(struct param (name type span) #:transparent)
(struct struct-decl (name fields span) #:transparent)
(struct enum-decl (name type-parameters variants span) #:transparent)
(struct enum-variant (name payload-types span) #:transparent)
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
(struct case-stmt (value arms span) #:transparent)
(struct case-arm (pattern body span) #:transparent)
(struct wildcard-pattern (span) #:transparent)
(struct literal-pattern (value span) #:transparent)
(struct variant-pattern (enum-name variant-name bindings span) #:transparent)

(struct literal (value span) #:transparent)
(struct name-ref (name span) #:transparent)
(struct call (name args span) #:transparent)
(struct enum-constructor (enum-name variant-name args span) #:transparent)
(struct function-ref (name span) #:transparent)
(struct invoke (target args span) #:transparent)
(struct named-arg (name value span) #:transparent)
(struct construct (type-name args span) #:transparent)
(struct list-lit (elements span) #:transparent)
(struct map-entry (key value span) #:transparent)
(struct map-lit (entries span) #:transparent)
(struct field-access (target name span [resolved #:auto #:mutable]) #:auto-value #f #:transparent)
(struct method-call (target name args span [resolved #:auto #:mutable]) #:auto-value #f #:transparent)
(struct typed-target (expression type) #:transparent)
(struct interpolation (parts span) #:transparent)
(struct block-lit (params body span) #:transparent)
(struct block-param (name type span) #:transparent)
(struct index-access (target index span) #:transparent)
(struct try-expr (operand span) #:transparent)
(struct unary (op op-span operand span) #:transparent)
(struct binary (op op-span left right span) #:transparent)

(define (node-span node)
  (cond
    [(program? node) (program-span node)]
    [(import-decl? node) (import-decl-span node)]
    [(export-decl? node) (export-decl-span node)]
    [(function-decl? node) (function-decl-span node)]
    [(param? node) (param-span node)]
    [(struct-decl? node) (struct-decl-span node)]
    [(enum-decl? node) (enum-decl-span node)]
    [(enum-variant? node) (enum-variant-span node)]
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
    [(case-stmt? node) (case-stmt-span node)]
    [(case-arm? node) (case-arm-span node)]
    [(wildcard-pattern? node) (wildcard-pattern-span node)]
    [(literal-pattern? node) (literal-pattern-span node)]
    [(variant-pattern? node) (variant-pattern-span node)]
    [(literal? node) (literal-span node)]
    [(name-ref? node) (name-ref-span node)]
    [(call? node) (call-span node)]
    [(enum-constructor? node) (enum-constructor-span node)]
    [(function-ref? node) (function-ref-span node)]
    [(invoke? node) (invoke-span node)]
    [(named-arg? node) (named-arg-span node)]
    [(construct? node) (construct-span node)]
    [(list-lit? node) (list-lit-span node)]
    [(map-entry? node) (map-entry-span node)]
    [(map-lit? node) (map-lit-span node)]
    [(field-access? node) (field-access-span node)]
    [(method-call? node) (method-call-span node)]
    [(typed-target? node) (node-span (typed-target-expression node))]
    [(interpolation? node) (interpolation-span node)]
    [(block-lit? node) (block-lit-span node)]
    [(block-param? node) (block-param-span node)]
    [(index-access? node) (index-access-span node)]
    [(try-expr? node) (try-expr-span node)]
    [(unary? node) (unary-span node)]
    [(binary? node) (binary-span node)]
    [else #f]))
