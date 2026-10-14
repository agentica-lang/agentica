#lang racket

(require rackunit
         racket/runtime-path
         (only-in "vm-diff-common.rkt" vm-file vm-built? compile-file run-process run-timeout))

(define-runtime-path fixtures "fixtures/vm")

(define (run-fixture name work #:input [input #""])
  (define bytecode (build-path work (string-append name ".agcb")))
  (compile-file (build-path fixtures (string-append name ".agc")) bytecode)
  (define result (run-process vm-file #:input input #:timeout run-timeout "--" (path->string bytecode)))
  (check-equal? (first result) 0 name)
  (check-equal? (third result) "" name)
  (string-split (second result) "\n" #:trim? #f))

(module+ test
  (when (vm-built? "std/binary tests")
    (define work (make-temporary-directory "agentica-binary~a"))
    (dynamic-wind
      void
      (lambda ()
        (test-case "std-binary.agc prints no mismatch and ends with the fixed summary"
          (define lines (run-fixture "std-binary" work))
          (check-false (for/or ([line (in-list lines)]) (string-prefix? line "mismatch")))
          (check-equal? (take-right lines 2) '("all checks ok" ""))
          (check-not-false (member "frames: 0 mismatches" lines))
          (check-not-false (member "error(u64 at offset 0 does not fit in Int)" lines))
          (check-not-false (member "error(frame limit -1 is negative)" lines)))
        (test-case "std-binary-vectors.agc checks every vector of its sidecar and prints no mismatch"
          (define input (file->bytes (build-path fixtures "std-binary-vectors.stdin")))
          (define vectors (sub1 (length (filter non-empty-string? (string-split (bytes->string/utf-8 input) "\n")))))
          (check-true (string-prefix? (bytes->string/utf-8 input) "# std-binary-vectors.stdin: made by python3"))
          (check-equal? (run-fixture "std-binary-vectors" work #:input input)
                        (list (format "~a vectors ok" vectors) ""))))
      (lambda () (delete-directory/files work)))))
