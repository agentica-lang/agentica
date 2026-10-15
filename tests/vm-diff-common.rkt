#lang racket

;; The helpers that the live front-end comparisons use (tests/frontend-*-test.rkt): the VM binary, compiling a file to
;; bytecode in process and running a process. The golden harness that lived here is tests/vm_diff_support.py. This file
;; goes with the live comparisons when the Racket front end does.

(require racket/file
         "../src/bytecode.rkt"
         "../src/checker.rkt"
         "../src/diagnostic.rkt"
         "../src/lexer.rkt"
         "../src/lower.rkt"
         "../src/modules.rkt"
         "../src/parser.rkt"
         "../src/source-file.rkt"
         "../src/source.rkt"
         racket/runtime-path)

(provide vm-file
         vm-built?
         compile-file
         run-process
         run-timeout)

(define-runtime-path root "..")
(define make-lock-wait 900)
(define run-timeout 60)
(define vm-binary (getenv "AGENTICA_VM_BINARY"))
(define vm-file
  (if vm-binary
      (path->complete-path vm-binary root)
      (build-path root "dist" (if (eq? (system-type) 'windows) "agentica-vm.exe" "agentica-vm"))))

(for ([name '(#"AGENTICA_VM_TRACE" #"AGENTICA_VM_TRACE_FILE" #"AGENTICA_FLUSH_TIMEOUT_MS")])
  (environment-variables-set! (current-environment-variables) name #f))
(for ([name '(#"LC_ALL" #"LANG")])
  (environment-variables-set! (current-environment-variables) name #"C.UTF-8"))
(environment-variables-set! (current-environment-variables) #"LC_MESSAGES" #f)

(define (vm-built? [tests "VM golden tests"])
  (define make (find-executable-path "make"))
  (define (make-vm)
    (define lock (build-path root "build" "vm-diff-make.lock"))
    (make-directory* (build-path root "build"))
    (define deadline (+ (current-inexact-milliseconds) (* 1000 make-lock-wait)))
    (let retry ()
      (define result
        (call-with-file-lock/timeout
         lock 'exclusive
         (lambda () (if (parameterize ([current-directory root]) (system* make "-s" "vm")) 'built 'failed))
         (lambda () 'busy)
         #:max-delay 0.2))
      (cond
        [(eq? result 'built) #t]
        [(and (eq? result 'busy) (< (current-inexact-milliseconds) deadline)) (retry)]
        [else #f])))
  (define built?
    (if vm-binary
        (file-exists? vm-file)
        (and make (make-vm))))
  (cond
    [built? #t]
    [(getenv "AGENTICA_REQUIRE_VM") (error 'vm-diff "the VM must build when AGENTICA_REQUIRE_VM is set")]
    [else (printf "SKIP ~a: make vm failed\n" tests) #f]))

(define (front-end path #:types [types #f])
  (define name (path->string path))
  (define text (read-source-file path name))
  (when (diagnostic? text) (error 'vm-diff "~a" (format-diagnostic text)))
  (define tokens (lex (source name text)))
  (define tree (if (diagnostic? tokens) tokens (parse tokens)))
  (define linked (if (diagnostic? tree) tree (link-program tree name)))
  (define checked (if (diagnostic? linked) linked (check linked #:types types)))
  (when (diagnostic? checked) (error 'vm-diff "~a" (format-diagnostic checked)))
  checked)

(define (run-process program #:input [input #""] #:timeout [timeout #f] . arguments)
  (define-values (process out in err) (apply subprocess #f #f #f program arguments))
  (define writer
    (thread (lambda ()
              (with-handlers ([exn:fail? void]) (write-bytes input in))
              (with-handlers ([exn:fail? void]) (close-output-port in)))))
  (define stderr #f)
  (define stdout #f)
  (define readers
    (list (thread (lambda () (set! stderr (port->string err))))
          (thread (lambda () (set! stdout (port->string out))))))
  (define finished (sync/timeout timeout process))
  (unless finished (subprocess-kill process #t))
  (for-each thread-wait readers)
  (thread-wait writer)
  (close-input-port out)
  (close-input-port err)
  (subprocess-wait process)
  (list (if finished (subprocess-status process) 'timeout) stdout stderr))

(define (compile-file path output)
  (define types (make-hasheq))
  (define checked (front-end path #:types types))
  (define (ok value)
    (when (diagnostic? value) (error 'vm-diff "compile failed: ~a" (format-diagnostic value)))
    value)
  (define data (ok (write-bytecode (ok (ir->bytecode (ok (lower checked types)))))))
  (call-with-output-file output #:exists 'truncate/replace
    (lambda (out) (void (write-bytes data out)))))
