#lang racket

(require rackunit
         racket/runtime-path
         (only-in "vm-diff-common.rkt" vm-file vm-built? compile-file run-process run-timeout))

(define-runtime-path fixtures "fixtures")

(define cases
  '(("vm/stack-trace-nested" ())
    ("vm/stack-trace-main" ())
    ("vm/stack-trace-import" ())
    ("vm/stack-trace-block" ())
    ("vm/stack-trace-tail" ())
    ("vm/stack-trace-recursion" ())
    ("vm/stack-trace-mutual" ())
    ("vm/stack-trace-task" ())
    ("vm/stack-trace-big" ())
    ("vm/step-limited/stack-trace-step-limit" ("--max-steps" "500"))
    ("vm/step-limited/stack-trace-task-step-limit" ("--max-steps" "500"))))

(define styles
  '(("plain" ())
    ("ai" ("--ai"))
    ("json" ("--json"))))

(define fixtures-prefix (path->string (path->directory-path (simplify-path fixtures))))

(define (sidecar name style)
  (build-path fixtures (format "~a.stack.~a" name style)))

(define (stderr-of name extra options work)
  (define bytecode (build-path work "program.agcb"))
  (compile-file (build-path fixtures (string-append name ".agc")) bytecode)
  (define result
    (apply run-process vm-file #:timeout run-timeout (append extra options (list "--" (path->string bytecode)))))
  (check-equal? (first result) 1 name)
  (string-replace (third result) fixtures-prefix "@fixtures/"))

(define (for-each-output proc)
  (define work (make-temporary-directory "agentica-stack~a"))
  (dynamic-wind
    void
    (lambda ()
      (for* ([entry (in-list cases)] [style (in-list styles)])
        (match-define (list name extra) entry)
        (match-define (list style-name options) style)
        (proc name style-name (stderr-of name extra options work))))
    (lambda () (delete-directory/files work))))

(module+ test
  (when (vm-built? "stack trace tests")
    (for-each-output
     (lambda (name style text)
       (test-case (format "~a in the ~a format" name style)
         (check-equal? text (file->string (sidecar name style))))))))

(module+ main
  (when (vm-built? "stack trace expectations")
    (for-each-output
     (lambda (name style text)
       (call-with-output-file (sidecar name style) #:exists 'truncate/replace
         (lambda (out) (write-string text out)))))))
