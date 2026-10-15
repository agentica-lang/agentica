#lang racket

(require rackunit json
         racket/runtime-path
         (only-in "vm-diff-common.rkt" vm-file vm-built? compile-file run-process run-timeout))

(define-runtime-path fixtures "fixtures")

(define python (find-executable-path "python3"))

(define (python-ready?)
  (cond
    [python #t]
    [(getenv "CI") (error 'vm-logger "Python 3 is required in CI")]
    [else (displayln "SKIP the logger peer: python3 is unavailable") #f]))

(define (bytecode-of name work)
  (define bytecode (build-path work (string-append name ".agcb")))
  (compile-file (build-path fixtures (string-append name ".agc")) bytecode)
  bytecode)

(define (run-vm bytecode #:input [input #""] #:directory [directory (current-directory)])
  (parameterize ([current-directory directory])
    (run-process vm-file #:input input #:timeout run-timeout "--" (path->string bytecode))))

(define (with-work proc)
  (define work (make-temporary-directory "agentica-logger~a"))
  (dynamic-wind void (lambda () (proc work)) (lambda () (delete-directory/files work))))


(module+ test
  (when (vm-built? "logger tests")
    (test-case "a run with no setup prints one INFO line on stderr and nothing else"
      (with-work
       (lambda (work)
         (define result (run-vm (bytecode-of "logger-default" work)))
         (check-equal? (first result) 0)
         (check-equal? (second result) "")
         (check-regexp-match #px"^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z INFO hello\n$" (third result)))))

    (test-case "the async handler example leaves every event in the file, in order"
      (with-work
       (lambda (work)
         (define result (run-vm (bytecode-of "logger-async" work) #:directory work))
         (check-equal? (first result) 0)
         (check-equal? (second result) "")
         (define lines (file->lines (build-path work "app.log")))
         (check-equal? (length lines) 3)
         (define events (map string->jsexpr lines))
         (check-equal? (map (lambda (e) (hash-ref e 'msg)) events)
                       '("server started" "request done" "cannot open the cache"))
         (check-equal? (map (lambda (e) (hash-ref e 'level)) events) '("info" "info" "error"))
         (check-equal? (hash-ref (second events) 'fields) (hasheq 'path "/items" 'status "200")))))

    (when (python-ready?)
      (test-case "the Python peer decodes the JSON lines and checks time_text against datetime"
        (with-work
         (lambda (work)
           (define peer (path->string (build-path fixtures "logger-peer.py")))
           (define directory (path->string work))
           (define made (run-process python #:timeout run-timeout peer "vectors" directory))
           (check-equal? (first made) 0 (third made))
           (define result
             (run-vm (bytecode-of "logger-peer" work) #:input (file->bytes (build-path work "ms.txt"))))
           (check-equal? (first result) 0 (third result))
           (display-to-file (second result) (build-path work "stdout.txt"))
           (display-to-file (third result) (build-path work "stderr.txt"))
           (define checked (run-process python #:timeout run-timeout peer "check" directory))
           (check-equal? (list (first checked) (string-trim (second checked))) '(0 "ok") (third checked))))))))
