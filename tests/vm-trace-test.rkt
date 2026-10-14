#lang racket

(require rackunit
         racket/runtime-path
         (only-in "vm-diff-common.rkt" vm-file vm-built? fixture-arg))

(define-runtime-path fixtures "fixtures/vm")
(define-runtime-path main-file "../src/main.rkt")

(define wait-seconds 60)

(for ([name '(#"AGENTICA_VM_TRACE" #"AGENTICA_VM_TRACE_FILE" #"AGENTICA_FLUSH_TIMEOUT_MS")])
  (environment-variables-set! (current-environment-variables) name #f))

(define trace-line
  (byte-pregexp
   (string->bytes/latin-1
    (string-append
     "^agc-trace \\+[0-9]+\\.[0-9]{6} (sched|io|proc|tls|loader|gc) [a-z_]+"
     "( [a-z_]+=([^ =\"\\\\\x00-\x20\x7f]+|\"([^\"\\\\\x00-\x1f\x7f]|\\\\[\"\\\\bfnrt]|\\\\u[0-9a-f]{4})*\"))*$"))))

(define (compile-fixture name work)
  (define out (build-path work (string-append name ".agcb")))
  (check-true (parameterize ([current-output-port (open-output-nowhere)])
                (system* (find-system-path 'exec-file) (path->string main-file) "compile"
                         (path->string (build-path fixtures (string-append name ".agc"))) "-o" (path->string out))))
  out)

(define (finish process out err)
  (define out-bytes #f)
  (define err-bytes #f)
  (define readers (list (thread (lambda () (set! out-bytes (port->bytes out))))
                        (thread (lambda () (set! err-bytes (port->bytes err))))))
  (define finished (sync/timeout wait-seconds process))
  (unless finished (subprocess-kill process #t))
  (for ([t readers]) (sync/timeout wait-seconds t))
  (close-input-port out)
  (close-input-port err)
  (check-true (and finished #t) (format "the VM finished within ~a s" wait-seconds))
  (list (subprocess-status process) out-bytes err-bytes))

(define (vm-version)
  (define-values (process out in err) (subprocess #f #f #f vm-file "--version"))
  (close-output-port in)
  (second (finish process out err)))

(define (fixture-args name tmp)
  (define file (build-path fixtures (string-append name ".args")))
  (if (file-exists? file)
      (for/list ([arg (file->value file)])
        (if (equal? arg "@tmp") (path->string tmp) (fixture-arg arg)))
      '()))

(define (fresh-directory dir)
  (delete-directory/files dir #:must-exist? #f)
  (make-directory* dir))

(define (run-vm bytecode #:env [settings '()] #:stdin [stdin-file #f] #:allow-run [allow-run? #f]
                #:args [args '()] #:tmp [tmp #f])
  (when tmp (fresh-directory tmp))
  (define env (environment-variables-copy (current-environment-variables)))
  (for ([setting settings]) (environment-variables-set! env (car setting) (cdr setting)))
  (define stdin (and stdin-file (open-input-file stdin-file)))
  (define-values (process out in err)
    (parameterize ([current-environment-variables env])
      (apply subprocess #f stdin #f vm-file
             (append (if allow-run? '("--allow-run") '()) (list "--" (path->string bytecode)) args))))
  (when in (close-output-port in))
  (when stdin (close-input-port stdin))
  (finish process out err))

(define (run-closed redirect bytecode stdin-file)
  (define-values (process out in err)
    (subprocess #f #f #f (find-executable-path "sh") "-c" (format "exec \"$0\" -- \"$1\" ~a <\"$2\"" redirect)
                vm-file bytecode stdin-file))
  (close-output-port in)
  (finish process out err))

(define (trace-lines file)
  (if (file-exists? file)
      (regexp-split #rx#"\n" (let ([b (file->bytes file)]) (subbytes b 0 (max 0 (sub1 (bytes-length b))))))
      '()))

(define gc-line
  #px#"^agc-trace \\+[0-9]+\\.[0-9]{6} gc collect at=(turn|end) count=[0-9]+ heap=[0-9]+ free=[0-9]+ since=[0-9]+$")

(define (line-category line)
  (bytes->string/latin-1 (cadr (regexp-match #px#"^agc-trace \\S+ (\\S+)" line))))

(define cases
  (list (list "task-stdin" "task-stdin.stdin" #f '("loader" "sched" "io"))
        (list "process-streams" #f #t '("loader" "sched" "io" "proc"))
        (list "files-handles" #f #f '("loader" "sched" "io"))
        (list "task-file-shared" #f #f '("loader" "sched" "io"))
        (list "task-fail" #f #f '("loader" "sched"))
        (list "tls-echo" #f #f '("loader" "sched" "io" "tls"))))

(module+ test
  (cond
    [(not (eq? (system-type 'os*) 'linux)) (displayln "SKIP VM trace tests: Linux only")]
    [(not (vm-built? "VM trace tests")) (void)]
    [(regexp-match? #rx#"trace off" (vm-version)) (displayln "SKIP VM trace tests: the VM was built with TRACE=0")]
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
             (define tmp (build-path work (string-append name "-tmp")))
             (define args (fixture-args name tmp))
             (define plain (run-vm bytecode #:stdin stdin-file #:allow-run allow-run? #:args args #:tmp tmp))
             (define file (build-path work (string-append name ".trace")))
             (define traced
               (run-vm bytecode #:stdin stdin-file #:allow-run allow-run? #:args args #:tmp tmp
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
           (define line-end (- (bytes-length err) (bytes-length (third plain))))
           (check-true (>= line-end 0))
           (check-equal? (subbytes err (max 0 line-end)) (third plain))
           (check-regexp-match #px#"^agc-trace cannot open \"?[^\n]*/missing/trace\"?\n$" (subbytes err 0 (max 0 line-end))))
         (test-case "an allocation-heavy run writes gc collect lines"
           (if (regexp-match? #rx#"sanitizer build" (vm-version))
               (displayln "SKIP gc trace test: sanitizer build, no libgc")
               (let* ([gc-bytecode (compile-fixture "map-large" work)]
                      [file (build-path work "map-large.trace")]
                      [gc-plain (run-vm gc-bytecode)]
                      [traced (run-vm gc-bytecode #:env (list (cons #"AGENTICA_VM_TRACE" #"gc")
                                                              (cons #"AGENTICA_VM_TRACE_FILE" (path->bytes file))))]
                      [lines (trace-lines file)])
                 (check-equal? traced gc-plain)
                 (check-true (pair? lines))
                 (for ([line lines])
                   (check-true (regexp-match? gc-line line) (format "gc line ~s" line))))))
         (test-case "a connection task names its server's group as its parent"
           (define file (build-path work "http-server-close.trace"))
           (match-define (list status _ _)
             (run-vm (compile-fixture "http-server-close" work)
                     #:env (list (cons #"AGENTICA_VM_TRACE" #"sched")
                                 (cons #"AGENTICA_VM_TRACE_FILE" (path->bytes file)))))
           (check-equal? status 0)
           (check-true (for/or ([line (trace-lines file)])
                         (regexp-match? #px#" sched spawn task=[0-9]+ parent=group:[1-9][0-9]* fn=" line))))
         (define stdin-file (build-path fixtures "task-stdin.stdin"))
         (define stdin-bytecode (build-path work "task-stdin.agcb"))
         (define stdin-plain (run-vm stdin-bytecode #:stdin stdin-file))
         (test-case "a VM started with stderr closed runs normally"
           (match-define (list status out _) (run-closed "2>&-" stdin-bytecode stdin-file))
           (check-equal? status (first stdin-plain))
           (check-equal? out (second stdin-plain)))
         (test-case "a VM started with stdout closed fails to write as before"
           (match-define (list status _ err) (run-closed ">&-" stdin-bytecode stdin-file))
           (check-equal? status 1)
           (check-true (regexp-match? #rx#"RUNTIME-INTERNAL" err))))
       (lambda () (delete-directory/files work #:must-exist? #f)))]))
