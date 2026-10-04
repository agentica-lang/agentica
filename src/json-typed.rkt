#lang racket

(require "ast.rkt" "json.rkt" "runtime-values.rkt" "builtin-types.rkt")

(provide decode-json json-schema)

(define (struct-table declarations)
  (define (reference type)
    (cond [(symbol? type) (type-ref (symbol->string type) '() #f)]
          [(eq? (car type) 'Struct) (type-ref (cadr type) '() #f)]
          [else (type-ref (symbol->string (car type)) (map reference (cdr type)) #f)]))
  (for/fold ([table (for/hash ([(name fields) (in-hash builtin-records)])
                     (values name (for/list ([field (in-list fields)])
                                    (field-decl (car field) (reference (cdr field)) #f))))])
            ([declaration (in-list declarations)] #:when (struct-decl? declaration))
    (hash-set table (struct-decl-name declaration) (struct-decl-fields declaration))))

(define (json-schema target declarations)
  (define structs (struct-table declarations))
  (define definitions (make-hash))
  (define active '())
  (define (reference name)
    (unless (hash-has-key? definitions name)
      (hash-set! definitions name #f)
      (unless (member name active)
        (hash-set! definitions name (object-schema name))))
    (hasheq '$ref (string-append "#/$defs/"
                    (string-replace (string-replace name "~" "~0") "/" "~1"))))
  (define (schema type)
    (define args (type-ref-args type))
    (case (string->symbol (type-ref-name type))
      [(Int) (hasheq 'type "integer" 'minimum (- (expt 2 63)) 'maximum (sub1 (expt 2 63)))]
      [(Float) (hasheq 'type "number")]
      [(Bool) (hasheq 'type "boolean")]
      [(String) (hasheq 'type "string")]
      [(List) (hasheq 'type "array" 'items (schema (car args)))]
      [(Map) (hasheq 'type "object" 'additionalProperties (schema (cadr args)))]
      [else (reference (type-ref-name type))]))
  (define (object-schema name)
    (set! active (cons name active))
    (define fields (hash-ref structs name))
    (define result
      (hasheq 'type "object"
              'properties (for/hasheq ([field (in-list fields)])
                            (values (string->symbol (field-decl-name field))
                                    (schema (field-decl-type field))))
              'required (map field-decl-name fields)))
    (set! active (cdr active))
    (when (hash-has-key? definitions name) (hash-set! definitions name result))
    result)
  (define root (object-schema target))
  (json-value
    (if (zero? (hash-count definitions)) root
        (hash-set root '$defs
                  (for/hasheq ([(name value) (in-hash definitions)])
                    (values (string->symbol name) value))))))

;; Type declarations are immutable and already validated by the checker.
(define (decode-json text target declarations)
  (with-handlers ([exn:fail? (lambda (failure) (result-error (exn-message failure)))])
    (define structs (struct-table declarations))
    (define data (json-value-data (read-json-value text)))
    (let/ec failed
      (define (fail path expected)
        (failed (result-error (format "~a: expected ~a" (if (equal? path "") "$" path) expected))))
      (define (decode data type path)
        (define name (type-ref-name type))
        (define args (type-ref-args type))
        (case (string->symbol name)
          [(Int)
           (unless (and (exact-integer? data) (<= (- (expt 2 63)) data (sub1 (expt 2 63))))
             (fail path "signed 64-bit Int"))
           data]
          [(Float)
           (define number (and (real? data) (exact->inexact data)))
           (unless (and number (rational? number)) (fail path "finite Float"))
           number]
          [(Bool) (unless (boolean? data) (fail path "Bool")) data]
          [(String) (unless (string? data) (fail path "String")) data]
          [(List)
           (unless (list? data) (fail path "array"))
           (for/list ([item (in-list data)] [index (in-naturals)])
             (decode item (car args) (format "~a[~a]" path index)))]
          [(Map)
           (unless (hash? data) (fail path "object"))
           (for/fold ([result (mapping (hash) '())]) ([key (in-list (sort (hash-keys data) symbol<?))])
             (define text-key (symbol->string key))
             (mapping-put result text-key
                          (decode (hash-ref data key) (cadr args)
                                  (format "~a[~s]" path text-key))))]
          [else
           (unless (hash? data) (fail path "object"))
           (instance name
             (for/hash ([field (in-list (hash-ref structs name))])
               (define key (field-decl-name field))
               (define field-path (if (equal? path "") key (string-append path "." key)))
               (unless (hash-has-key? data (string->symbol key)) (fail field-path "required field"))
               (values key (decode (hash-ref data (string->symbol key))
                                   (field-decl-type field) field-path))))]))
      (result-ok (decode data (type-ref target '() #f) "")))))
