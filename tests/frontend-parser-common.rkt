#lang racket

(require racket/runtime-path
         "../src/ast.rkt"
         "../src/diagnostic.rkt"
         "../src/lexer.rkt"
         "../src/parser.rkt"
         "../src/source.rkt"
         "frontend-lexer-common.rkt")

(provide parser-text
         parser-inputs
         part-text?
         pseudo?
         pseudo-label
         pseudo-children
         part-text-text
         shape
         current-update-universe
         node-children
         number-tree
         emit-tree!
         (struct-out parser-input)
         golden-file
         write-parser-goldens)

(struct parser-input (name path))
(struct part-text (text))
(struct pseudo (label children))

(define-runtime-path root "..")
(define-runtime-path fixtures "fixtures/frontend/parser")

(define (kids role items)
  (for/list ([item (in-list items)]) (cons role item)))

(define (optional role item)
  (if item (list (cons role item)) '()))

(define (value-text value)
  (cond
    [(exact-integer? value) (format "int:~a" value)]
    [(flonum? value) (format "float:bits:~a" (float-bits value))]
    [(string? value) (string-append "string:" (quote-text value))]
    [(eq? value #t) "bool:true"]
    [(eq? value #f) "bool:false"]
    [(eq? value 'nil) "nil"]
    [else (error 'parser-text "unexpected literal value ~s" value)]))

;  An imported name with its span, and `as` with the local name and its span for a rename.
(define (import-name-text entry)
  (define original (format "~a@~a" (quote-text (import-name-name entry)) (span-text (import-name-span entry))))
  (if (equal? (import-name-name entry) (import-name-local entry))
      original
      (format "~a as ~a@~a" original (quote-text (import-name-local entry))
              (span-text (import-name-local-span entry)))))

(define (name-attr name) (string-append " name=" (quote-text name)))

(define (op-attrs op op-span)
  (format " op=~a op-span=~a" op (span-text op-span)))

; The user structs of the linked program, when it is printed: the linker leaves the privacy rule of a struct
; update as a predicate, which the text form shows as the sorted names it accepts.
(define current-update-universe (make-parameter #f))

(define (update-attrs node)
  (define visible (struct-update-visible node))
  (if (and visible (current-update-universe))
      (format " visible=[~a]"
              (string-join (map quote-text (sort (filter visible (current-update-universe)) string<?)) ","))
      ""))

; The kind, attributes and children of a node. doc-of gives the doc text of a node or #f; the text form
; prints it where the node has one.
(define (shape node doc-of)
  (define (doc-attr)
    (define text (doc-of node))
    (if text (string-append " doc=" (quote-text text)) ""))
  (cond
    [(program? node)
     (values "program"
             (if (program-module-doc node) (string-append " module-doc=" (quote-text (program-module-doc node))) "")
             (kids "declaration" (program-declarations node)))]
    [(import-decl? node)
     (values "import-decl"
             (if (import-decl-alias node)
                 (format " path=~a alias=~a" (quote-text (import-decl-path node)) (quote-text (import-decl-alias node)))
                 (format " path=~a names=[~a]" (quote-text (import-decl-path node))
                         (string-join (map import-name-text (import-decl-names node)) ",")))
             '())]
    [(export-decl? node)
     (values "export-decl" (doc-attr) (list (cons "declaration" (export-decl-declaration node))))]
    [(const-decl? node)
     (values "const-decl"
             (string-append (name-attr (const-decl-name node)) (if (const-decl-exported node) " exported=true" "") (doc-attr))
             (append (optional "type" (const-decl-type node)) (list (cons "value" (const-decl-value node)))))]
    [(function-decl? node)
     (values "function-decl" (string-append (name-attr (function-decl-name node)) (doc-attr))
             (append (kids "param" (function-decl-params node))
                     (list (cons "result" (function-decl-result node)))
                     (kids "body" (function-decl-body node))))]
    [(param? node) (values "param" (name-attr (param-name node)) (list (cons "type" (param-type node))))]
    [(struct-decl? node)
     (values "struct-decl" (string-append (name-attr (struct-decl-name node)) (doc-attr))
             (kids "field" (struct-decl-fields node)))]
    [(field-decl? node)
     (values "field-decl" (string-append (name-attr (field-decl-name node)) (doc-attr))
             (list (cons "type" (field-decl-type node))))]
    [(enum-decl? node)
     (values "enum-decl"
             (string-append (name-attr (enum-decl-name node))
                            (format " type-parameters=[~a]"
                                    (string-join (map quote-text (enum-decl-type-parameters node)) ","))
                            (doc-attr))
             (kids "variant" (enum-decl-variants node)))]
    [(enum-variant? node)
     (values "enum-variant" (string-append (name-attr (enum-variant-name node)) (doc-attr))
             (kids "payload" (enum-variant-payload-types node)))]
    [(type-ref? node) (values "type-ref" (name-attr (type-ref-name node)) (kids "arg" (type-ref-args node)))]
    [(binding? node)
     (values "binding" (name-attr (binding-name node))
             (append (optional "type" (binding-type node)) (list (cons "value" (binding-value node)))))]
    [(return-stmt? node) (values "return-stmt" "" (optional "value" (return-stmt-value node)))]
    [(expr-stmt? node) (values "expr-stmt" "" (list (cons "value" (expr-stmt-value node))))]
    [(if-branch? node)
     (values "if-branch" ""
             (cons (cons "condition" (if-branch-condition node)) (kids "body" (if-branch-body node))))]
    [(if-stmt? node)
     (values "if-stmt" ""
             (append (kids "branch" (if-stmt-branches node))
                     (if (if-stmt-else-body node)
                         (list (cons #f (pseudo "else:" (kids "body" (if-stmt-else-body node)))))
                         '())))]
    [(while-stmt? node)
     (values "while-stmt" ""
             (cons (cons "condition" (while-stmt-condition node)) (kids "body" (while-stmt-body node))))]
    [(for-stmt? node)
     (values "for-stmt" (string-append " variable=" (quote-text (for-stmt-var node)))
             (cons (cons "iterable" (for-stmt-iterable node)) (kids "body" (for-stmt-body node))))]
    [(loop-control? node) (values "loop-control" (format " kind=~a" (loop-control-kind node)) '())]
    [(case-stmt? node)
     (values "case-stmt" ""
             (cons (cons "value" (case-stmt-value node)) (kids "arm" (case-stmt-arms node))))]
    [(case-arm? node)
     (values "case-arm" ""
             (cons (cons "pattern" (case-arm-pattern node)) (kids "body" (case-arm-body node))))]
    [(wildcard-pattern? node) (values "wildcard-pattern" "" '())]
    [(literal-pattern? node)
     (values "literal-pattern" (string-append " value=" (value-text (literal-pattern-value node))) '())]
    [(variant-pattern? node)
     (values "variant-pattern"
             (format " enum=~a variant=~a bindings=[~a]"
                     (quote-text (variant-pattern-enum-name node))
                     (quote-text (variant-pattern-variant-name node))
                     (string-join (for/list ([name (in-list (variant-pattern-bindings node))])
                                    (if name (quote-text name) "-"))
                                  ","))
             '())]
    [(literal? node) (values "literal" (string-append " value=" (value-text (literal-value node))) '())]
    [(name-ref? node) (values "name-ref" (name-attr (name-ref-name node)) '())]
    [(const-ref? node) (values "const-ref" (name-attr (const-ref-name node)) '())]
    [(call? node)
     (values "call" (format "~a piped=~a" (name-attr (call-name node)) (if (call-piped node) "true" "false"))
             (kids "arg" (call-args node)))]
    [(enum-constructor? node)
     (values "enum-constructor"
             (format " enum=~a variant=~a" (quote-text (enum-constructor-enum-name node))
                     (quote-text (enum-constructor-variant-name node)))
             (kids "arg" (enum-constructor-args node)))]
    [(function-ref? node) (values "function-ref" (name-attr (function-ref-name node)) '())]
    [(invoke? node)
     (values "invoke" ""
             (cons (cons "target" (invoke-target node)) (kids "arg" (invoke-args node))))]
    [(named-arg? node) (values "named-arg" (name-attr (named-arg-name node)) (list (cons "value" (named-arg-value node))))]
    [(construct? node)
     (values "construct" (string-append " type=" (quote-text (construct-type-name node)))
             (kids "arg" (construct-args node)))]
    [(struct-update? node)
     (values "struct-update" (update-attrs node)
             (cons (cons "target" (struct-update-target node)) (kids "arg" (struct-update-args node))))]
    [(list-lit? node) (values "list-lit" "" (kids "element" (list-lit-elements node)))]
    [(map-entry? node)
     (values "map-entry" "" (list (cons "key" (map-entry-key node)) (cons "value" (map-entry-value node))))]
    [(map-lit? node) (values "map-lit" "" (kids "entry" (map-lit-entries node)))]
    [(field-access? node)
     (values "field-access" (name-attr (field-access-name node)) (list (cons "target" (field-access-target node))))]
    [(method-call? node)
     (values "method-call" (name-attr (method-call-name node))
             (cons (cons "target" (method-call-target node)) (kids "arg" (method-call-args node))))]
    [(interpolation? node)
     (values "interpolation" ""
             (for/list ([part (in-list (interpolation-parts node))])
               (cons "part" (if (string? part) (part-text part) part))))]
    [(block-lit? node)
     (values "block-lit" "" (append (kids "param" (block-lit-params node)) (kids "body" (block-lit-body node))))]
    [(block-param? node) (values "block-param" (name-attr (block-param-name node)) (optional "type" (block-param-type node)))]
    [(index-access? node)
     (values "index-access" ""
             (list (cons "target" (index-access-target node)) (cons "index" (index-access-index node))))]
    [(try-expr? node) (values "try-expr" "" (list (cons "operand" (try-expr-operand node))))]
    [(unary? node)
     (values "unary" (op-attrs (unary-op node) (unary-op-span node)) (list (cons "operand" (unary-operand node))))]
    [(binary? node)
     (values "binary" (op-attrs (binary-op node) (binary-op-span node))
             (list (cons "left" (binary-left node)) (cons "right" (binary-right node))))]
    [(type-expression? node) (values "type-expression" (name-attr (type-expression-name node)) '())]
    [else (error 'parser-text "unexpected node ~s" node)]))

; The nodes below a node in source order, without the text parts of an interpolation.
(define (node-children node)
  (define-values (kind attrs children) (shape node (lambda (_) #f)))
  (let visit ([children children])
    (append*
     (for/list ([child (in-list children)])
       (define item (cdr child))
       (cond
         [(pseudo? item) (visit (pseudo-children item))]
         [(part-text? item) '()]
         [else (list item)])))))

; The id of every node of a tree, in post-order from first-id: a node comes after its children and the
; root has the last id.
(define (number-tree root first-id)
  (define ids (make-hasheq))
  (define counter first-id)
  (let walk ([node root])
    (for-each walk (node-children node))
    (hash-set! ids node counter)
    (set! counter (add1 counter)))
  ids)

; Calls (emit! line) for a node and the nodes below it, one line each, in the text form. id-of and doc-of
; give the id and the doc of a node; notes-of the text added at the end of its line (the checker's text form
; adds the type of an expression).
(define (emit-tree! emit! node role indent id-of doc-of #:notes [notes-of (lambda (node) "")])
  (let walk ([node node] [role role] [indent indent])
    (define-values (kind attrs children) (shape node doc-of))
    (emit! (format "~a~a~a #~a ~a~a~a" indent (if role (string-append role ": ") "") kind
                   (id-of node) (span-text (node-span node)) attrs (notes-of node)))
    (let visit ([children children] [indent (string-append indent "  ")])
      (for ([child (in-list children)])
        (define item (cdr child))
        (cond
          [(pseudo? item)
           (emit! (string-append indent (pseudo-label item)))
           (visit (pseudo-children item) (string-append indent "  "))]
          [(part-text? item) (emit! (string-append indent "part: text " (quote-text (part-text-text item))))]
          [else (walk item (car child) indent)])))))

(define (program-lines program first-id)
  (define docs (program-docs program))
  (define ids (number-tree program first-id))
  (define out '())
  (emit-tree! (lambda (line) (set! out (cons line out))) program #f ""
              (lambda (node) (hash-ref ids node))
              (lambda (node) (hash-ref docs (node-span node) #f)))
  (reverse out))

(define (parser-text text #:first-id [first-id 0])
  (define tokens (lex (source "input.agc" text)))
  (cond
    [(diagnostic? tokens) (diagnostic-line tokens)]
    [else
     (define program (parse tokens))
     (if (diagnostic? program)
         (diagnostic-line program)
         (string-join (program-lines program first-id) "\n"))]))

(define (parser-inputs)
  (for/list ([file (in-list (sort (directory-list fixtures) path<?))]
             #:when (path-has-extension? file #".input"))
    (define name (path->string (path-replace-extension file #"")))
    (parser-input name (string-append "tests/fixtures/frontend/parser/" (path->string file)))))

(define (golden-file input)
  (build-path fixtures (string-append (parser-input-name input) ".ast")))

(define (write-parser-goldens)
  (define inputs (parser-inputs))
  (for ([input (in-list inputs)])
    (define text (file->string (build-path root (parser-input-path input))))
    (display-to-file (string-append (parser-text text) "\n") (golden-file input) #:exists 'truncate/replace))
  (define expected (map (lambda (input) (path->string (file-name-from-path (golden-file input)))) inputs))
  (for ([file (in-list (directory-list fixtures))]
        #:when (and (path-has-extension? file #".ast")
                    (not (member (path->string file) expected))))
    (delete-file (build-path fixtures file)))
  (printf "frontend parser: ~a goldens\n" (length inputs)))

(module+ main
  (write-parser-goldens))
