#lang racket

(require rackunit
         racket/runtime-path
         (only-in "vm-diff-common.rkt" vm-file vm-built? compile-file run-process run-timeout))

(define-runtime-path fixtures "fixtures")

(define python (find-executable-path "python3"))

(define (python-ready?)
  (cond
    [python #t]
    [(getenv "CI") (error 'vm-monotonic "Python 3 is required in CI")]
    [else (displayln "SKIP the monotonic peer: python3 is unavailable") #f]))

(module+ test
  (when (and (vm-built? "monotonic tests") (python-ready?))
    (test-case "Time.monotonic_ns reads the same clock as Python's time.monotonic_ns"
      (define work (make-temporary-directory "agentica-monotonic~a"))
      (dynamic-wind
       void
       (lambda ()
         (define bytecode (build-path work "monotonic-peer.agcb"))
         (compile-file (build-path fixtures "monotonic-peer.agc") bytecode)
         (define result
           (run-process python #:timeout run-timeout
                        (path->string (build-path fixtures "monotonic-peer.py"))
                        (path->string vm-file) (path->string bytecode)))
         (check-equal? (first result) 0 (third result))
         (check-regexp-match #px"^(ok|skip: .*)\n$" (second result)))
       (lambda () (delete-directory/files work))))))
