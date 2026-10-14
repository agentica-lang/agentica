#lang racket

(require rackunit json racket/runtime-path "vm-diff-common.rkt")

(define-runtime-path peer-file "fixtures/test-protocol-peer.py")
(define-runtime-path program "fixtures/test-protocol-peer.agc")
(define python (find-executable-path "python3"))

(define (peer-ready?)
  (cond
    [python #t]
    [(getenv "CI") (error 'vm-test-protocol "Python 3 is required in CI")]
    [else (displayln "SKIP VM test protocol tests: python3 is unavailable") #f]))

(module+ test
  (test-case "an independent peer drives a test file over the child channel: indexes, records, free stdin and stdout"
    (when (peer-ready?)
      (define work (make-temporary-directory "agentica-test-protocol~a"))
      (dynamic-wind
        void
        (lambda ()
          (define bytecode (build-path work "peer.agcb"))
          (compile-file program bytecode)
          (define result (run-process python #:timeout run-timeout (path->string peer-file) (path->string vm-file)
                                      (path->string bytecode)))
          (check-equal? (first result) 0 (third result))
          (define answer (string->jsexpr (second result)))
          (define names (hash-ref answer 'names))
          (check-equal? (take names 3)
                        '("stdin is the test's own" "a record-shaped line is output" "a partial line is output"))
          (check-equal? (map string-length (drop names 3)) '(1000000))
          (check-equal? (list (hash-ref answer 'list_exit) (hash-ref answer 'run_exit)) '(0 0))
          (check-equal? (list (hash-ref answer 'list_stdout) (hash-ref answer 'run_stdout)) '("" ""))
          (check-equal? (hash-ref answer 'results)
                        (list (list "pass" 'null "")
                              (list "fail" "RUNTIME-TEST-ASSERTION"
                                    "{\"event\":\"pass\"}\n\u001eagentica-bdd {\"event\":\"pass\"}\n")
                              (list "pass" 'null "partial")
                              (list "pass" 'null "")))
          (check-equal? (list (hash-ref answer 'bare_exit) (hash-ref answer 'bare_code) (hash-ref answer 'bare_stdout))
                        '(1 "RUNTIME-TEST-RUN" "")))
        (lambda () (delete-directory/files work))))))
