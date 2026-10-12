#lang racket

(require rackunit
         racket/runtime-path)

(define-runtime-path root "..")
(define-runtime-path fixtures "fixtures/vm")
(define-runtime-path main-file "../src/main.rkt")

(define wait-seconds 60)
(define make-lock-wait 900)
(define vm-binary (getenv "AGENTICA_VM_BINARY"))
(define vm-file (if vm-binary (path->complete-path vm-binary root) (build-path root "dist" "agentica-vm")))

(for ([name '(#"AGENTICA_VM_TRACE" #"AGENTICA_VM_TRACE_FILE")])
  (environment-variables-set! (current-environment-variables) name #f))

(define trace-line
  (byte-pregexp
   (string->bytes/latin-1
    (string-append
     "^agc-trace \\+[0-9]+\\.[0-9]{6} (sched|io|proc|tls|loader|gc) [a-z_]+"
     "( [a-z_]+=([^ =\"\\\\\x00-\x20\x7f]+|\"([^\"\\\\\x00-\x1f\x7f]|\\\\[\"\\\\bfnrt]|\\\\u[0-9a-f]{4})*\"))*$"))))

(define (vm-built?)
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
  (if vm-binary (file-exists? vm-file) (and make (make-vm))))

(define (compile-fixture name work)
  (define out (build-path work (string-append name ".agcb")))
  (check-true (parameterize ([current-output-port (open-output-nowhere)])
                (system* (find-system-path 'exec-file) (path->string main-file) "compile"
                         (path->string (build-path fixtures (string-append name ".agc"))) "-o" (path->string out))))
  out)

(define (run-vm bytecode #:env [settings '()] #:stdin [stdin-file #f] #:allow-run [allow-run? #f])
  (define env (environment-variables-copy (current-environment-variables)))
  (for ([setting settings]) (environment-variables-set! env (car setting) (cdr setting)))
  (define stdin (and stdin-file (open-input-file stdin-file)))
  (define-values (process out in err)
    (parameterize ([current-environment-variables env])
      (apply subprocess #f stdin #f vm-file
             (append (if allow-run? '("--allow-run") '()) (list "--" (path->string bytecode))))))
  (when in (close-output-port in))
  (when stdin (close-input-port stdin))
  (define out-bytes #f)
  (define err-bytes #f)
  (define readers (list (thread (lambda () (set! out-bytes (port->bytes out))))
                        (thread (lambda () (set! err-bytes (port->bytes err))))))
  (define finished (sync/timeout wait-seconds process))
  (unless finished (subprocess-kill process #t))
  (for ([t readers]) (sync/timeout wait-seconds t))
  (close-input-port out)
  (close-input-port err)
  (check-true (and finished #t) (format "~a finished within ~a s" bytecode wait-seconds))
  (list (subprocess-status process) out-bytes err-bytes))

(define (trace-lines file)
  (if (file-exists? file)
      (regexp-split #rx#"\n" (let ([b (file->bytes file)]) (subbytes b 0 (max 0 (sub1 (bytes-length b))))))
      '()))

(define (line-category line)
  (bytes->string/latin-1 (cadr (regexp-match #px#"^agc-trace \\S+ (\\S+)" line))))

(define cases
  (list (list "task-stdin" "task-stdin.stdin" #f '("loader" "sched" "io"))
        (list "process-streams" #f #t '("loader" "sched" "io" "proc"))
        (list "task-fail" #f #f '("loader" "sched"))))

(module+ test
  (cond
    [(not (eq? (system-type 'os*) 'linux)) (displayln "SKIP VM trace tests: Linux only")]
    [(not (vm-built?))
     (if (getenv "AGENTICA_REQUIRE_VM")
         (error 'vm-trace "the VM must build when AGENTICA_REQUIRE_VM is set")
         (displayln "SKIP VM trace tests: make vm failed"))]
    [else
     (define work (make-temporary-directory "agentica-trace~a"))
     (dynamic-wind
       void
       (lambda ()
         (for ([c cases])
           (match-define (list name stdin allow-run? categories) c)
           (test-case (format "~a: tracing to a file changes no exit code, stdout or stderr" name)
             (define bytecode (compile-fixture name work))
             (define stdin-file (and stdin (build-path fixtures stdin)))
             (define plain (run-vm bytecode #:stdin stdin-file #:allow-run allow-run?))
             (define file (build-path work (string-append name ".trace")))
             (define traced
               (run-vm bytecode #:stdin stdin-file #:allow-run allow-run?
                       #:env (list (cons #"AGENTICA_VM_TRACE" #"all")
                                   (cons #"AGENTICA_VM_TRACE_FILE" (path->bytes file)))))
             (check-equal? traced plain)
             (check-equal? (bitwise-and (file-or-directory-permissions file 'bits) #o077) 0)
             (define lines (trace-lines file))
             (check-true (pair? lines))
             (for ([line lines])
               (check-true (regexp-match? trace-line line) (format "trace line ~s" line)))
             (define seen (remove-duplicates (map line-category lines)))
             (for ([category categories])
               (check-not-false (member category seen) (format "category ~a in ~a" category seen)))))
         (define bytecode (build-path work "task-fail.agcb"))
         (define plain (run-vm bytecode))
         (test-case "an unknown category writes one warning and changes nothing else"
           (match-define (list status out err) (run-vm bytecode #:env (list (cons #"AGENTICA_VM_TRACE" #"nope"))))
           (check-equal? status (first plain))
           (check-equal? out (second plain))
           (check-equal? err (bytes-append #"agc-trace unknown category \"nope\"\n" (third plain))))
         (test-case "a trace file that cannot be opened writes one line and traces nothing"
           (define missing (build-path work "missing" "trace"))
           (match-define (list status out err)
             (run-vm bytecode #:env (list (cons #"AGENTICA_VM_TRACE" #"all")
                                          (cons #"AGENTICA_VM_TRACE_FILE" (path->bytes missing)))))
           (check-equal? status (first plain))
           (check-equal? out (second plain))
           (check-equal? err (bytes-append #"agc-trace cannot open " (path->bytes missing) #"\n" (third plain))))
         (test-case "a VM started with stderr closed runs normally"
           (define stdin-file (build-path fixtures "task-stdin.stdin"))
           (define bytecode (build-path work "task-stdin.agcb"))
           (match-define (list status out _) (run-vm bytecode #:stdin stdin-file))
           (define-values (process sh-out sh-in sh-err)
             (subprocess #f #f #f (find-executable-path "sh") "-c" "exec \"$0\" -- \"$1\" 2>&- <\"$2\""
                         vm-file bytecode stdin-file))
           (close-output-port sh-in)
           (define closed-out #f)
           (define reader (thread (lambda () (set! closed-out (port->bytes sh-out)))))
           (define finished (sync/timeout wait-seconds process))
           (unless finished (subprocess-kill process #t))
           (sync/timeout wait-seconds reader)
           (close-input-port sh-out)
           (close-input-port sh-err)
           (check-true (and finished #t))
           (check-equal? (subprocess-status process) status)
           (check-equal? closed-out out)))
       (lambda () (delete-directory/files work #:must-exist? #f)))]))
