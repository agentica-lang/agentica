#lang racket

; Freezes what tests/frontend-catalog-test.rkt reads from the Racket source: the variants of the Rule enum, which
; compiler/builtin_model.agc must declare. tests/test_frontend_catalog.py compares the Agentica catalog with them. Run by
; `make frontend-freeze`. The catalog golden itself is written by tests/frontend-catalog-common.rkt (`make goldens`).

(require "frontend-freeze-common.rkt"
         (only-in "../tools/gen-builtins-data.rkt" rule-variants))

(module+ main
  (write-frozen "catalog/rules.expected"
                (string-append* (for/list ([variant (in-list (rule-variants))]) (string-append variant "\n"))))
  (printf "catalog/rules.expected\n"))
