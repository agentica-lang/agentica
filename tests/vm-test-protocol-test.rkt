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
  (test-case "an independent peer drives a test file over pipes: token, indexes, records and output"
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
          (check-equal? (hash-ref answer 'names)
                        '("the stdin file is empty" "a forged record is output" "a record follows a partial line"))
          (check-equal? (list (hash-ref answer 'list_exit) (hash-ref answer 'run_exit)) '(0 0))
          (check-equal? (hash-ref answer 'results)
                        (list (list "pass" 'null '())
                              (list "fail" "RUNTIME-TEST-ASSERTION"
                                    (list "\u001eagentica-bdd {\"event\":\"pass\",\"token\":\"guess\"}"))
                              (list "pass" 'null '("partial")))))
        (lambda () (delete-directory/files work))))))
