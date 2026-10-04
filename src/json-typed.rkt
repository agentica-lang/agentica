#lang racket

(require "ast.rkt" "json.rkt" "runtime-values.rkt")

(provide decode-json)

;; Type declarations are immutable and already validated by the checker.
(define (decode-json text target declarations)
  (with-handlers ([exn:fail? (lambda (failure) (result-error (exn-message failure)))])
    (define structs
      (for/hash ([declaration (in-list declarations)] #:when (struct-decl? declaration))
        (values (struct-decl-name declaration) (struct-decl-fields declaration))))
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
