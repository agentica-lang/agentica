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
         "../src/checker.rkt")

(provide builtins-data-source rule-variant rule-variants)

(define-runtime-path output "../compiler/builtins_data.agc")

;; Rows per generated function, so that no function passes the 60 lines of the style rule.
(define chunk-size 40)

;; "#{" inside an Agentica string starts an interpolation, so a text with one cannot be written as data.
(define (quoted text)
  (when (regexp-match? #rx"#[{]" text)
    (error 'gen-builtins-data "the text ~s contains an interpolation start" text))
  (format "~s" text))

(define (string-list names)
  (string-append "[" (string-join (map quoted names) ", ") "]"))

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

;; A type of the catalog as an Agentica expression. A bare symbol that is no type name is a type variable (T, K, V,
;; A, B, R); (Await R) is the builtin enum written like a generic type.
(define (type-code type)
  (match type
    [(? symbol?)
     (define name (symbol->string type))
     (cond
       [(member type '(Int Float Bool String Nil Void Json Range)) (string-append "Types.Type." name)]
       [(memq type opaque-types) (format "Types.Type.Opaque(~a)" (quoted name))]
       [(regexp-match? #px"^[A-Z]$" name) (format "Types.Type.Var(~a)" (quoted name))]
       [else (error 'gen-builtins-data "unknown type symbol ~a" type)])]
    [(list 'Struct name) (format "Types.Type.Struct(~a)" (quoted name))]
    [(list 'TypeVar name) (format "Types.Type.Var(~a)" (quoted name))]
    [(list 'Enum name args ...) (enum-code name args)]
    [(list 'Await args ...) (enum-code "Await" args)]
    [(list (and head (or 'Result 'Task 'Channel 'List 'Set)) item)
     (format "Types.Type.~a(~a)" head (type-code item))]
    [(list 'Map key value) (format "Types.Type.Map(~a, ~a)" (type-code key) (type-code value))]
    [(list 'Fn parts ...)
     (format "Types.Type.Fn([~a], ~a)"
             (string-join (map type-code (drop-right parts 1)) ", ")
             (type-code (last parts)))]
    [_ (error 'gen-builtins-data "unknown type ~s" type)]))

(define (enum-code name args)
  (format "Types.Type.Enum(~a, [~a])" (quoted name) (string-join (map type-code args) ", ")))

(define (named-code name type)
  (format "Model.Named(name: ~a, type: ~a)" (quoted name) (type-code type)))

(define (builtin-code entry)
  (format "Model.Builtin(name: ~a, parameters: [~a], result: ~a, rule: Model.Rule.~a, implementation: ~a, effects: ~a, description: ~a, alternatives: [~a])"
          (quoted (builtin-name entry))
          (string-join (for/list ([parameter (in-list (builtin-parameters entry))])
                         (named-code (symbol->string (car parameter)) (cadr parameter)))
                       ", ")
          (type-code (builtin-result entry))
          (rule-variant (builtin-rule entry))
          (quoted (builtin-implementation entry))
          (string-list (map symbol->string (builtin-effects entry)))
          (quoted (builtin-description entry))
          (string-join (map builtin-code (builtin-alternatives entry)) ", ")))

(define (chunks items size)
  (if (<= (length items) size)
      (list items)
      (cons (take items size) (chunks (drop items size) size))))

(define (rows-functions)
  (define groups (chunks (all-entries) chunk-size))
  (for/list ([group (in-list groups)] [index (in-naturals 1)])
    (string-append
     (format "def rows_~a() -> List[Model.Builtin]\n  return [\n" index)
     (string-join (for/list ([entry (in-list group)]) (string-append "    " (builtin-code entry))) ",\n")
     "\n  ]\nend\n")))

(define (rows-export count)
  (string-append
   "## Every builtin, sorted by name.\nexport def builtin_rows() -> List[Model.Builtin]\n  return "
   (string-join (for/list ([index (in-range 1 (add1 count))]) (format "rows_~a()" index)) ".concat(")
   (make-string (sub1 count) #\))
   "\nend\n"))

(define (records-export)
  (string-append
   "## The builtin record types, sorted by name.\nexport def records() -> List[Model.Record]\n  return [\n"
   (string-join
    (for/list ([name (in-list (sort (hash-keys builtin-records) string<?))])
      (format "    Model.Record(name: ~a, fields: [~a])" (quoted name)
              (string-join (for/list ([field (in-list (hash-ref builtin-records name))])
                             (named-code (car field) (cdr field)))
                           ", ")))
    ",\n")
   "\n  ]\nend\n"))

(define (enums-export)
  (string-append
   "## The builtin enums, whose variants are written without an import.\nexport def enums() -> List[Model.EnumDef]\n  return [\n"
   (string-join
    (for/list ([declaration (in-list builtin-enum-declarations)])
      (match-define (list* name parameters variants) declaration)
      (format "    Model.EnumDef(name: ~a, parameters: ~a, variants: [~a])" (quoted name) (string-list parameters)
              (string-join (for/list ([variant (in-list variants)])
                             (format "Model.Variant(name: ~a, payload: [~a])" (quoted (car variant))
                                     (string-join (map type-code (cdr variant)) ", ")))
                           ", ")))
    ",\n")
   "\n  ]\nend\n"))

(define (names-export doc name names)
  (format "## ~a\nexport def ~a() -> List[String]\n  return ~a\nend\n" doc name (string-list names)))

(define (std-only-export)
  (define rows
    (for/list ([name (in-list std-only-modules)])
      (define import (hash-ref std-only-imports name))
      (format "~a: ~a" (quoted name) (string-list (list (car import) (cdr import))))))
  (string-append
   "## The modules only std/ may call: each name with the std module that wraps it and the alias its help shows.\n"
   "export def std_only_imports() -> Map[String, List[String]]\n"
   "  return {" (string-join rows ", ") "}\nend\n"))

(define (builtins-data-source)
  (define count (length (chunks (all-entries) chunk-size)))
  (string-join
   (append
    (list (string-append
           "## The builtin catalog of src/builtins.rkt and src/builtin-types.rkt, and the reserved type names of src/checker.rkt, as data. "
           "Generated by tools/gen-builtins-data.rkt: change src/ and run the tool, never edit this file by hand (a test checks it).\n\n"
           "import Model from \"builtin_model\"\nimport Types from \"types\"\n")
          (rows-export count)
          (records-export)
          (enums-export)
          (names-export "The handle types a task can be given with Task.spawn_owning." "handle_types" (map symbol->string handle-types))
          (names-export "The builtin types with no structure: handles and TestCase." "opaque_types" (map symbol->string opaque-types))
          (names-export "The type names no declaration or import alias may take." "reserved_type_names"
                        (sort reserved-type-names string<?))
          (std-only-export))
    (rows-functions))
   "\n"))

(module+ main
  (display-to-file (builtins-data-source) output #:exists 'truncate/replace))
