#lang racket

(require rackunit
         json
         racket/runtime-path
         (only-in "vm-diff-common.rkt" vm-file vm-built? compile-file run-process run-timeout))

(define-runtime-path fixtures "fixtures/vm")

(define spans
  '(("int-shift-negative" "RUNTIME-INVALID-COUNT" 4 21 4 26)
    ("int-shift-right-negative" "RUNTIME-INVALID-COUNT" 3 27 3 29)
    ("int-shift-right-unsigned-negative" "RUNTIME-INVALID-COUNT" 3 36 3 60)
    ("float-from-bits32-negative" "RUNTIME-INVALID-NUMBER" 3 26 3 28)
    ("float-from-bits32-range" "RUNTIME-INVALID-NUMBER" 3 26 3 36)))

(define (diagnostic-of name work)
  (define bytecode (build-path work (string-append name ".agcb")))
  (compile-file (build-path fixtures (string-append name ".agc")) bytecode)
  (define result (run-process vm-file #:timeout run-timeout "--json" "--" (path->string bytecode)))
  (check-equal? (first result) 1 name)
  (string->jsexpr (last (string-split (third result) "\n"))))

(module+ test
  (when (vm-built? "bit builtin span tests")
    (define work (make-temporary-directory "agentica-bits~a"))
    (dynamic-wind
      void
      (lambda ()
        (for ([entry (in-list spans)])
          (match-define (list name code start-line start-column end-line end-column) entry)
          (test-case (format "~a halts with ~a at the bad argument" name code)
            (define diagnostic (diagnostic-of name work))
            (define range (hash-ref diagnostic 'range))
            (define (position key line column)
              (check-equal? (list (hash-ref (hash-ref range key) 'line) (hash-ref (hash-ref range key) 'column))
                            (list line column)
                            name))
            (check-equal? (hash-ref diagnostic 'code) code)
            (position 'start start-line start-column)
            (position 'end end-line end-column))))
      (lambda () (delete-directory/files work)))))
