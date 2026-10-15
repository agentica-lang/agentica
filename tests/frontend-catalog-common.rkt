#lang racket

(require racket/runtime-path
         "frontend-lexer-common.rkt"
         "../src/builtins.rkt"
         "../src/builtin-types.rkt"
         (only-in "../src/checker.rkt" reserved-type-names))

(provide catalog-text
         catalog-probes
         catalog-golden
         write-catalog-golden)

(define-runtime-path catalog-golden "fixtures/frontend/catalog/catalog.text")

; The questions put to both catalogs after the tables: near:WORD is did-you-mean among the public builtin names,
; ref:NAME/ARITY the form of NAME with that many arguments, std:NAME whether NAME is inside a std-only module,
; type:WORD did-you-mean among the record and enum names plus the primitive and handle type names, as the checker
; offers for an unknown type.
; A name with a "@N::" prefix is a linked name: only candidates with the same prefix count, so it finds nothing here.
(define catalog-probes
  '("near:pust" "near:put" "near:prnt" "near:Task.spwn" "near:Strng.length" "near:String.lenght" "near:List.apend"
    "near:Map.hsa_key?" "near:@3::puts" "near:gets" "near:xyz" "near:ok" "near:error" "near:Dir.mkdr" "near:IO.puts"
    "near:JSON.pase" "near:Int.time" "near:Set.includ?" "near:Result.unwrap" "near:Time.now_ms"
    "ref:puts/1" "ref:puts/0" "ref:ok/0" "ref:ok/1" "ref:ok/2" "ref:Task.await/1" "ref:Task.await/2" "ref:Task.await/3"
    "ref:Map.get/2" "ref:Map.get/3" "ref:Map.get/4" "ref:Nope/1" "ref:HttpWire.client/5" "ref:List.map/2"
    "std:HttpWire.client" "std:LogRegistry.level" "std:Http.x" "std:HttpWireX.y" "std:puts" "std:HttpWire" "std:.x"
    "type:Strng" "type:Hedaer" "type:LogLevl" "type:Lst" "type:@3::Strng" "type:@3::Hedaer" "type:Socet"))

(define shared-type-names
  (append '("Int" "Float" "Bool" "String" "Nil" "Void" "List" "Map" "Set" "Result" "Json" "Fn" "Task" "Channel" "Range")
          (map symbol->string opaque-types)))

(define (quoted-list items)
  (string-append "[" (string-join (map quote-text items) ", ") "]"))

; One form alone: builtin-signature of a copy without alternatives.
(define (form-signature form)
  (builtin-signature (builtin (builtin-name form) (builtin-parameters form) (builtin-result form) (builtin-rule form)
                              (builtin-implementation form) (builtin-effects form) (builtin-description form))))

(define (rule-name rule)
  (if rule
      (string-append* (for/list ([part (in-list (string-split (symbol->string rule) "-"))])
                        (string-append (string-upcase (substring part 0 1)) (substring part 1))))
      "Plain"))

(define (form-line form)
  (format "~a rule=~a impl=~a effects=~a desc=~a"
          (form-signature form) (rule-name (builtin-rule form)) (quote-text (builtin-implementation form))
          (quoted-list (map symbol->string (builtin-effects form))) (quote-text (builtin-description form))))

(define (builtin-lines entry)
  (define forms (cons entry (builtin-alternatives entry)))
  (cons (format "builtin ~a forms=~a" (builtin-name entry) (length forms))
        (for/list ([form (in-list forms)]) (string-append "  " (form-line form)))))

(define (record-lines)
  (for/list ([name (in-list (sort (hash-keys builtin-records) string<?))])
    (format "record ~a ~a" name
            (string-join (for/list ([field (in-list (hash-ref builtin-records name))])
                           (format "~a: ~a" (car field) (type->string (cdr field))))
                         ", "))))

(define (variant-text variant)
  (if (null? (cdr variant))
      (car variant)
      (format "~a(~a)" (car variant) (string-join (map type->string (cdr variant)) ", "))))

(define (enum-lines)
  (for/list ([declaration (in-list (sort builtin-enum-declarations string<? #:key car))])
    (format "enum ~a parameters=~a variants=~a" (car declaration) (quoted-list (cadr declaration))
            (string-join (map variant-text (cddr declaration)) " | "))))

(define (name-lines)
  (list (format "public ~a" (quoted-list (sort (public-builtin-names) string<?)))
        (format "bare ~a" (quoted-list (sort (filter (lambda (name) (not (regexp-match? #rx"[.]" name))) (hash-keys builtins)) string<?)))
        (format "opaque ~a" (quoted-list (sort (map symbol->string opaque-types) string<?)))
        (format "handles ~a" (quoted-list (sort (map symbol->string handle-types) string<?)))
        (format "reserved ~a" (quoted-list (sort reserved-type-names string<?)))
        (format "std-only ~a"
                (string-join (for/list ([name (in-list std-only-modules)])
                               (define import (hash-ref std-only-imports name))
                               (format "~a=~a as ~a" name (car import) (cdr import)))
                             ", "))))

(define (probe-line probe)
  (match-define (list _ kind rest) (regexp-match #rx"^([^:]*):(.*)$" probe))
  (string-append
   probe " -> "
   (case kind
     [("near") (let ([help (did-you-mean rest (public-builtin-names))]) (if help (quote-text help) "-"))]
     [("ref")
      (match-define (list _ name arity) (regexp-match #rx"^(.*)/([0-9]+)$" rest))
      (define form (builtin-ref name (string->number arity)))
      (if form (form-line form) "-")]
     [("type")
      (define help (did-you-mean rest (append (hash-keys builtin-records) (hash-keys builtin-enums)) #:shared shared-type-names))
      (if help (quote-text help) "-")]
     [else (if (std-only-name? rest) "true" "false")])))

; The text form of the catalog; compiler/catalog.agc prints the same for the same probes.
(define (catalog-text probes)
  (string-join
   (append (append-map builtin-lines (for/list ([name (in-list (sort (hash-keys builtins) string<?))]) (hash-ref builtins name)))
           (record-lines) (enum-lines) (name-lines)
           (map probe-line probes))
   "\n"))

(define (write-catalog-golden)
  (make-parent-directory* catalog-golden)
  (display-to-file (string-append (catalog-text catalog-probes) "\n") catalog-golden #:exists 'truncate/replace)
  (printf "frontend catalog: 1 golden\n"))

(module+ main
  (write-catalog-golden))
