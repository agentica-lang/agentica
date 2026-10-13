#lang racket

(require file/sha1
         json
         (only-in "ast.rkt" program-span)
         racket/os
         racket/random
         "bdd-driver.rkt"
         "builtins.rkt"
         "bytecode.rkt"
         "checker.rkt"
         "diagnostic.rkt"
         "lexer.rkt"
         "lower.rkt"
         "parser.rkt"
         "modules.rkt"
         "source.rkt"
         "version.rkt"
         "vm-launch.rkt")

(define (temporary-bytecode-path)
  (build-path (find-system-path 'temp-dir)
              (format "agentica-~a.agcb" (bytes->hex-string (crypto-random-bytes 16)))))

(define (write-temporary-bytecode path data created!)
  (define out (parameterize-break #f
                (begin0 (open-output-file path #:exists 'error #:permissions #o600)
                        (created!))))
  (dynamic-wind void (lambda () (write-bytes data out)) (lambda () (close-output-port out))))

(define (delete-temporary path)
  (with-handlers ([exn:fail:filesystem? void])
    (delete-file path)))

(define (run-vm-process vm bytecode-file options program-args)
  (define (stream port) (and (file-stream-port? port) port))
  (define stdout (current-output-port))
  (define stderr (current-error-port))
  (define stdin (current-input-port))
  (flush-output stdout)
  (flush-output stderr)
  (define-values (process from-vm to-vm from-vm-err)
    (with-handlers ([exn:fail? (lambda (_) (values #f #f #f #f))])
      (apply subprocess (stream stdout) (stream stdin) (stream stderr) vm
             (append options (list "--driver-pid" (number->string (getpid)) "--" (path->string bytecode-file))
                     program-args))))
  (define feeder #f)
  (define read-failed? #f)
  (define (feed)
    (define buffer (make-bytes 65536))
    (define failed?
      (let loop ()
        (define count (with-handlers ([exn:fail? (lambda (_) 'failed)]) (read-bytes-avail! buffer stdin)))
        (cond
          [(eq? count 'failed) #t]
          [(exact-positive-integer? count)
           (and (with-handlers ([exn:fail? (lambda (_) #f)])
                  (write-bytes buffer to-vm 0 count)
                  (flush-output to-vm)
                  #t)
                (loop))]
          [else #f])))
    (when (and failed? (eq? (subprocess-status process) 'running))
      (set! read-failed? #t)
      (stop-vm process))
    (with-handlers ([exn:fail? void]) (close-output-port to-vm)))
  (and process
       (dynamic-wind
         void
         (lambda ()
           (parameterize-break #f (when to-vm (set! feeder (thread feed))))
           (define (pump from to)
             (thread (lambda ()
                       (with-handlers ([exn:fail? (lambda (_) (copy-port from (open-output-nowhere)))])
                         (copy-port from to))
                       (close-input-port from))))
           (define readers
             (filter values (list (and from-vm (pump from-vm stdout))
                                  (and from-vm-err (pump from-vm-err stderr)))))
           (subprocess-wait process)
           (for-each thread-wait readers)
           (flush-output stdout)
           (flush-output stderr)
           (if read-failed? 'read-failed (subprocess-status process)))
         (lambda ()
           (when feeder (kill-thread feeder))
           (when to-vm (with-handlers ([exn:fail? void]) (close-output-port to-vm)))
           (parameterize-break #f (stop-vm process))))))

(module+ main
  (define dump? #f)
  (define dump-ir? #f)
  (define style 'plain)
  (define max-steps #f)
  (define allow-run? #f)
  (define seed #f)
  (define step-files '())
  (define raw-arguments
    (command-line
     #:program "agentica"
     #:usage-help
     "Programs run on the bytecode VM (agentica-vm, or AGENTICA_VM)."
     #:once-each
     [("--version") "print the version and exit" (displayln version) (exit 0)]
     [("--allow-run") "allow Process.spawn to run child programs" (set! allow-run? #t)]
     [("--max-steps") count "limit execution to N expression/statement entries"
      (define parsed (string->number count))
      (unless (and (regexp-match? #px"^[0-9]+$" count) (exact-positive-integer? parsed))
        (eprintf "agentica: --max-steps needs a positive integer\n")
        (exit 2))
      (set! max-steps parsed)]
     [("--seed") n "seed Random with N (0..2147483647) for repeatable runs"
      (define parsed (string->number n))
      (unless (and (regexp-match? #px"^[0-9]+$" n) (<= 0 parsed 2147483647))
        (eprintf "agentica: --seed needs an integer from 0 to 2147483647\n")
        (exit 2))
      (set! seed parsed)]
     [("--dump") "print the checked tree instead of running it" (set! dump? #t)]
     [("--dump-ir") "print the lowered VM IR instead of running it" (set! dump-ir? #t)]
     [("--ai") "print diagnostics as compact text for an agent" (set! style 'ai)]
     [("--json") "print diagnostics as one JSON object" (set! style 'json)]
     #:multi
     [("--steps") path "the step program of agentica test" (set! step-files (append step-files (list path)))]
     #:args arguments
     arguments))
  (when (and (pair? raw-arguments) (equal? (car raw-arguments) "test"))
    (for ([argument (in-list (cdr raw-arguments))])
      (when (member argument '("--ai" "--json"))
        (set! style (if (equal? argument "--json") 'json 'ai))))
    (define (show-report code text)
      (display text)
      (exit code))
    (define (usage-error message)
      (call-with-values (lambda () (bdd-usage-report message style)) show-report))
    (define paths '())
    (let loop ([arguments (cdr raw-arguments)])
      (cond
        [(null? arguments) (void)]
        [(equal? (car arguments) "--steps")
         (when (null? (cdr arguments))
           (usage-error "option needs a value"))
         (set! step-files (append step-files (list (cadr arguments))))
         (loop (cddr arguments))]
        [(member (car arguments) '("--json" "--ai"))
         (set! style (if (equal? (car arguments) "--json") 'json 'ai))
         (loop (cdr arguments))]
        [(equal? (car arguments) "--allow-run")
         (set! allow-run? #t)
         (loop (cdr arguments))]
        [(string-prefix? (car arguments) "--")
         (usage-error (format "unknown option ~a" (car arguments)))]
        [else (set! paths (append paths (list (car arguments)))) (loop (cdr arguments))]))
    (call-with-values
     (lambda ()
       (run-agentica-test (if (null? paths) '("specs/") paths) step-files
                          #:style style #:allow-run allow-run? #:seed seed #:vm (find-vm)))
     show-report))
  (when (and (pair? raw-arguments) (equal? (car raw-arguments) "help"))
    ;; Only help consumes a trailing option; program args stay untouched.
    (when (equal? (last raw-arguments) "--json")
      (set! style 'json)
      (set! raw-arguments (drop-right raw-arguments 1)))
    (unless (= (length raw-arguments) 2)
      (eprintf "usage: agentica help NAME --json\n")
      (exit 2))
    (define name (cadr raw-arguments))
    (define entry (and (not (std-only-name? name)) (builtin-ref name)))
    (unless entry
      (eprintf "agentica: unknown builtin ~a~a\n" name
               (let ([suggestion (did-you-mean name (public-builtin-names))])
                 (if suggestion (string-append "; " suggestion) "")))
      (exit 2))
    (displayln (if (eq? style 'json)
                   (jsexpr->string (builtin->jsexpr entry))
                   (format "~a\n~a" (builtin-signature entry) (builtin-description entry))))
    (exit 0))
  (define check-only? (and (pair? raw-arguments) (equal? (car raw-arguments) "check")))
  (define compile? (and (pair? raw-arguments) (equal? (car raw-arguments) "compile")))
  (define arguments (if (or check-only? compile?) (cdr raw-arguments) raw-arguments))
  (unless (if compile?
              (and (= (length arguments) 3) (equal? (cadr arguments) "-o") (not dump?) (not dump-ir?))
              (>= (length arguments) 1))
    (eprintf "usage: agentica [--version] [--dump] [--dump-ir] [--ai|--json] [--max-steps N] [--seed N] [--allow-run] [check] <source-file> [args...]\n       agentica [--ai|--json] compile <source-file> -o <file.agcb>\n       agentica help NAME [--json]\n       agentica [--ai|--json] [--allow-run] [--seed N] test [PATH...] [--steps FILE]\n")
    (exit 2))
  (define source-file (car arguments))
  (define program-args (cdr arguments))
  (define (fail! problem)
    (displayln (case style
                 [(ai) (format-diagnostic-ai problem)]
                 [(json) (jsexpr->string (diagnostic->jsexpr problem))]
                 [else (format-diagnostic problem)])
               (current-error-port))
    (exit 1))

  (define text
    (with-handlers ([exn:fail:filesystem?
                     (lambda (_)
                       (eprintf "agentica: cannot read ~a\n" source-file)
                       (exit 2))])
      (file->string source-file)))
  (define input (source source-file text))

  (define lexed (lex input))
  (when (diagnostic? lexed) (fail! lexed))
  (define tree (parse lexed))
  (when (diagnostic? tree) (fail! tree))
  (define linked (link-program tree source-file))
  (when (diagnostic? linked) (fail! linked))
  (define types (make-hasheq))
  (define checked (check linked #:types types))
  (when (diagnostic? checked) (fail! checked))
  (define (lowered)
    (define ir (lower checked types))
    (when (diagnostic? ir) (fail! ir))
    ir)
  (define (bytecode-data [ir (lowered)])
    (define code (ir->bytecode ir))
    (when (diagnostic? code) (fail! code))
    (define data (write-bytecode code))
    (when (diagnostic? data) (fail! data))
    data)
  (define (run-on-vm ir)
    (define data (bytecode-data ir))
    (define vm (find-vm))
    (unless (and (file-exists? vm) (memq 'execute (file-or-directory-permissions vm)))
      (eprintf "agentica: cannot find the VM at ~a; run make vm or set AGENTICA_VM\n" vm)
      (exit 2))
    (define bytecode-file (temporary-bytecode-path))
    (define created? #f)
    (define options
      (append (if max-steps (list "--max-steps" (number->string max-steps)) '())
              (if seed (list "--seed" (number->string seed)) '())
              (if allow-run? '("--allow-run") '())
              (case style [(ai) '("--ai")] [(json) '("--json")] [else '()])))
    (define status
      (dynamic-wind
        void
        (lambda ()
          (if (with-handlers ([exn:fail:filesystem? (lambda (_) #f)])
                (write-temporary-bytecode bytecode-file data (lambda () (set! created? #t)))
                #t)
              (run-vm-process vm bytecode-file options program-args)
              'no-temporary))
        (lambda () (when created? (delete-temporary bytecode-file)))))
    (when (eq? status 'read-failed)
      (fail! (diagnostic 'RUNTIME-INTERNAL "cannot read standard input" (program-span checked))))
    (when (eq? status 'no-temporary)
      (eprintf "agentica: cannot write a temporary file in ~a\n" (find-system-path 'temp-dir))
      (exit 2))
    (unless (exact-integer? status)
      (eprintf "agentica: cannot run the VM at ~a\n" vm)
      (exit 2))
    (exit status))
  (cond
    [check-only? (displayln (if (eq? style 'json) "{\"ok\":true}" "check ok"))]
    [dump? (pretty-print checked)]
    [dump-ir? (displayln (format-ir (lowered)))]
    [compile?
     (define data (bytecode-data))
     (define output-file (caddr arguments))
     (with-handlers ([exn:fail:filesystem?
                      (lambda (_)
                        (eprintf "agentica: cannot write ~a\n" output-file)
                        (exit 2))])
       (call-with-output-file output-file #:exists 'truncate/replace
         (lambda (out) (void (write-bytes data out)))))]
    [else (run-on-vm (lowered))]))
