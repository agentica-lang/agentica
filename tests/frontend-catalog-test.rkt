#lang racket

(require rackunit
         racket/runtime-path
         "frontend-catalog-common.rkt"
         "frontend-lexer-common.rkt"
         "vm-diff-common.rkt"
         "../src/builtins.rkt"
         "../tools/gen-builtins-data.rkt")

(define-runtime-path root "..")
(define-runtime-path entry "../compiler/catalog.agc")
(define-runtime-path data "../compiler/builtins_data.agc")
(define-runtime-path model "../compiler/builtin_model.agc")

(define (with-bytecode proc) (call-with-bytecode compile-file entry proc))

(module+ test
  (test-case "compiler/builtins_data.agc is the catalog of src/"
    (unless (equal? (file->string data) (builtins-data-source))
      (fail "compiler/builtins_data.agc is out of date: run racket tools/gen-builtins-data.rkt")))

  (test-case "the Rule enum of compiler/builtin_model.agc has the rules of src/builtins.rkt"
    (define text (file->string model))
    (define declared
      (string-split (cadr (regexp-match #px"export enum Rule\n(.*?)\nend" text)) "\n"))
    (check-equal? (sort (map string-trim declared) string<?) (rule-variants)))

  (test-case "the Racket text form of the catalog is the golden"
    (check-equal? (string-append (catalog-text catalog-probes) "\n") (file->string catalog-golden)))

  (when (vm-built? "frontend catalog tests")
    (with-bytecode
      (lambda (work bytecode)
        (test-case "the Agentica catalog prints the golden: tables, signatures, lookups and did-you-mean"
          (define result
            (parameterize ([current-directory root])
              (apply run-process vm-file #:timeout run-timeout "--" (path->string bytecode) catalog-probes)))
          (check-equal? (first result) 0 (third result))
          (check-equal? (third result) "")
          (check-equal? (second result) (file->string catalog-golden)))))))
