#lang racket/base

;; Writes compiler/builtins_data.agc: the builtin catalog of src/builtins.rkt and src/builtin-types.rkt (and the
;; reserved type names of src/checker.rkt) as Agentica data. A test compares the file with builtins-data-source,
;; so a new builtin row, record, enum or reserved name shows up there: run this tool after changing them.

(require racket/file
         racket/list
         racket/match
         racket/runtime-path
         racket/string
         "../src/builtins.rkt"
         "../src/builtin-types.rkt"
         "../src/checker.rkt"
         "agc-format.rkt")

(provide builtins-data-source rule-variant rule-variants)

(define-runtime-path output "../compiler/builtins_data.agc")

;; Lines of rows per generated function, so that no function passes the 60 lines of the style rule.
(define rows-per-function 55)

;; "#{" inside an Agentica string starts an interpolation, so a text with one cannot be written as data.
(define (quoted text)
  (when (regexp-match? #rx"#[{]" text)
    (error 'gen-builtins-data "the text ~s contains an interpolation start" text))
  (format "~s" text))

(define (camel-case text)
  (string-append* (for/list ([part (in-list (string-split text "-"))])
                    (string-append (string-upcase (substring part 0 1)) (substring part 1)))))

;; The Rule variant of a src/builtins.rkt rule: #f is Plain, task-spawn is TaskSpawn.
(define (rule-variant rule)
  (if rule (camel-case (symbol->string rule)) "Plain"))

(define (all-entries)
  (for*/list ([name (in-list (sort (hash-keys builtins) string<?))]) (hash-ref builtins name)))

;; The variants used by the catalog, sorted: the test compares them with the Rule enum of compiler/builtin_model.agc.
(define (rule-variants)
  (sort (remove-duplicates
         (for*/list ([entry (in-list (all-entries))] [variant (in-list (cons entry (builtin-alternatives entry)))])
           (rule-variant (builtin-rule variant))))
        string<?))

;; A call or a list of the generated data: see tools/agc-format.rkt.
(define (call head . items) (group "" (string-append head "(") ")" items))
(define (labeled label node)
  (if (string? node)
      (string-append label ": " node)
      (struct-copy group node [prefix (string-append label ": ")])))
(define (list-of items) (group "" "[" "]" items))
(define (text-lit text) (lit "" text quoted))
(define (labeled-lit label text) (lit (string-append label ": ") text quoted))

;; A type of the catalog as an Agentica expression. A bare symbol that is no type name is a type variable (T, K, V,
;; A, B, R); (Await R) is the builtin enum written like a generic type.
(define (type-code type)
  (match type
    [(? symbol?)
     (define name (symbol->string type))
     (cond
       [(member type '(Int Float Bool String Nil Void Json Range)) (string-append "Types.Type." name)]
       [(memq type opaque-types) (call "Types.Type.Opaque" (quoted name))]
       [(regexp-match? #px"^[A-Z]$" name) (call "Types.Type.Var" (quoted name))]
       [else (error 'gen-builtins-data "unknown type symbol ~a" type)])]
    [(list 'Struct name) (call "Types.Type.Struct" (quoted name))]
    [(list 'TypeVar name) (call "Types.Type.Var" (quoted name))]
    [(list 'Enum name args ...) (enum-code name args)]
    [(list 'Await args ...) (enum-code "Await" args)]
    [(list (and head (or 'Result 'Task 'Channel 'List 'Set)) item)
     (call (format "Types.Type.~a" head) (type-code item))]
    [(list 'Map key value) (call "Types.Type.Map" (type-code key) (type-code value))]
    [(list 'Fn parts ...)
     (call "Types.Type.Fn" (list-of (map type-code (drop-right parts 1))) (type-code (last parts)))]
    [_ (error 'gen-builtins-data "unknown type ~s" type)]))

(define (enum-code name args)
  (call "Types.Type.Enum" (quoted name) (list-of (map type-code args))))

(define (named-code name type)
  (call "Model.Named" (labeled-lit "name" name) (labeled "type" (type-code type))))

(define (builtin-code entry)
  (call "Model.Builtin"
        (labeled-lit "name" (builtin-name entry))
        (labeled "parameters"
                 (list-of (for/list ([parameter (in-list (builtin-parameters entry))])
                            (named-code (symbol->string (car parameter)) (cadr parameter)))))
        (labeled "result" (type-code (builtin-result entry)))
        (string-append "rule: Model.Rule." (rule-variant (builtin-rule entry)))
        (labeled-lit "implementation" (builtin-implementation entry))
        (labeled "effects" (list-of (map text-lit (map symbol->string (builtin-effects entry)))))
        (labeled-lit "description" (builtin-description entry))
        (labeled "alternatives" (list-of (map builtin-code (builtin-alternatives entry))))))

;; The type, record and enum code above builds trees; these helpers write them at an indentation.
(define (render-row node indent)
  (string-append (make-string indent #\space) (render node indent 1)))

(define (string-list names)
  (list-of (map text-lit names)))

;; The rows of the catalog, split into groups whose function stays within `rows-per-function` lines.
(define (row-groups)
  (define rows (for/list ([entry (in-list (all-entries))]) (render-row (builtin-code entry) 4)))
  (define (line-count row) (add1 (length (regexp-match* #rx"\n" row))))
  (let loop ([rows rows] [current '()] [lines 0] [done '()])
    (cond
      [(null? rows) (reverse (if (null? current) done (cons (reverse current) done)))]
      [(and (pair? current) (> (+ lines (line-count (car rows))) rows-per-function))
       (loop rows '() 0 (cons (reverse current) done))]
      [else (loop (cdr rows) (cons (car rows) current) (+ lines (line-count (car rows))) done)])))

(define (rows-functions groups)
  (for/list ([group (in-list groups)] [index (in-naturals 1)])
    (string-append
     (format "def rows_~a() -> List[Model.Builtin]\n  return [\n" index)
     (string-join group ",\n")
     ",\n  ]\nend\n")))

(define (rows-export count)
  (string-append
   (doc-comment "Every builtin, sorted by name.")
   "export def builtin_rows() -> List[Model.Builtin]\n  rows = rows_1()\n"
   (string-append* (for/list ([index (in-range 2 (add1 count))])
                     (format "  rows = rows.concat(rows_~a())\n" index)))
   "  return rows\nend\n"))

(define (list-export doc name type items)
  (string-append
   (doc-comment doc)
   (format "export def ~a() -> ~a\n  return [\n" name type)
   (string-append* (for/list ([item (in-list items)]) (string-append (render-row item 4) ",\n")))
   "  ]\nend\n"))

(define (records-export)
  (list-export "The builtin record types, sorted by name." "records" "List[Model.Record]"
               (for/list ([name (in-list (sort (hash-keys builtin-records) string<?))])
                 (call "Model.Record"
                       (labeled-lit "name" name)
                       (labeled "fields" (list-of (for/list ([field (in-list (hash-ref builtin-records name))])
                                                    (named-code (car field) (cdr field)))))))))

(define (enums-export)
  (list-export "The builtin enums, whose variants are written without an import." "enums" "List[Model.EnumDef]"
               (for/list ([declaration (in-list builtin-enum-declarations)])
                 (match-define (list* name parameters variants) declaration)
                 (call "Model.EnumDef"
                       (labeled-lit "name" name)
                       (labeled "parameters" (string-list parameters))
                       (labeled "variants"
                                (list-of (for/list ([variant (in-list variants)])
                                           (call "Model.Variant"
                                                 (labeled-lit "name" (car variant))
                                                 (labeled "payload" (list-of (map type-code (cdr variant))))))))))))

(define (names-export doc name names)
  (string-append (doc-comment doc)
                 (format "export def ~a() -> List[String]\n  return ~a\nend\n" name
                         (render (string-list names) 2 0 7))))

(define (std-only-export)
  (define rows
    (for/list ([name (in-list std-only-modules)])
      (define import (hash-ref std-only-imports name))
      (labeled (quoted name) (string-list (list (car import) (cdr import))))))
  (string-append
   (doc-comment (string-append "The modules only std/ may call: each name with the std module that wraps it and the "
                               "alias its help shows."))
   "export def std_only_imports() -> Map[String, List[String]]\n"
   "  return " (render (group "" "{" "}" rows) 2 0 7) "\nend\n"))

(define (builtins-data-source)
  (define groups (row-groups))
  (string-join
   (append
    (list (string-append
           (doc-comment (string-append "The builtin catalog of src/builtins.rkt and src/builtin-types.rkt, and the "
                                       "reserved type names of src/checker.rkt, as data. Generated by "
                                       "tools/gen-builtins-data.rkt: change src/ and run the tool, never edit this "
                                       "file by hand (a test checks it)."))
           "\nimport Model from \"builtin_model\"\nimport Types from \"types\"\n")
          (rows-export (length groups))
          (records-export)
          (enums-export)
          (names-export "The handle types a task can be given with Task.spawn_owning." "handle_types"
                        (map symbol->string handle-types))
          (names-export "The builtin types with no structure: handles and TestCase." "opaque_types"
                        (map symbol->string opaque-types))
          (names-export "The type names no declaration or import alias may take." "reserved_type_names"
                        (sort reserved-type-names string<?))
          (std-only-export))
    (rows-functions groups))
   "\n"))

(module+ main
  (display-to-file (builtins-data-source) output #:exists 'truncate/replace))
