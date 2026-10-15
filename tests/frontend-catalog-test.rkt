#lang racket

;; What is left of the Racket side of the catalog test: the Racket text form against its golden, and the generated data
;; file against the Racket tables. tests/test_frontend_catalog.py runs the Agentica catalog against the golden.

(require rackunit
         racket/runtime-path
         "frontend-catalog-common.rkt"
         "../tools/gen-builtins-data.rkt")

(define-runtime-path data "../compiler/builtins_data.agc")

(module+ test
  (test-case "compiler/builtins_data.agc is the catalog of src/"
    (unless (equal? (file->string data) (builtins-data-source))
      (fail "compiler/builtins_data.agc is out of date: run racket tools/gen-builtins-data.rkt")))

  (test-case "the Racket text form of the catalog is the golden"
    (check-equal? (string-append (catalog-text catalog-probes) "\n") (file->string catalog-golden))))
