#lang racket

(require file/sha1
         json
         racket/os
         racket/random
         "bdd-runner.rkt"
         "builtins.rkt"
         "bytecode.rkt"
         "checker.rkt"
         "diagnostic.rkt"
         "evaluator.rkt"
         "lexer.rkt"
         "lower.rkt"
         "parser.rkt"
         "modules.rkt"
         "source.rkt"
         "version.rkt")

(define vm-name (if (eq? (system-type) 'windows) "agentica-vm.exe" "agentica-vm"))

(define (find-vm)
  (define override (getenv "AGENTICA_VM"))
  (define here (variable-reference->module-source (#%variable-reference)))
  (cond
    [(and override (not (equal? override ""))) (path->complete-path override)]
    [(path? here)
     (define-values (directory _name _dir?) (split-path here))
     (simplify-path (build-path directory 'up "dist" vm-name) #f)]
    [else
     (define run (find-system-path 'run-file))
     (define program (normalize-path (or (find-executable-path run) run)))
     (build-path (path-only program) vm-name)]))

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
  (define feeder
    (and to-vm
         (thread (lambda ()
                   (with-handlers ([exn:fail? void])
                     (define buffer (make-bytes 65536))
                     (let loop ()
                       (define count (read-bytes-avail! buffer stdin))
                       (unless (eof-object? count)
                         (write-bytes buffer to-vm 0 count)
                         (flush-output to-vm)
                         (loop))))
                   (with-handlers ([exn:fail? void]) (close-output-port to-vm))))))
  (and process
       (dynamic-wind
         void
         (lambda ()
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
           (subprocess-status process))
         (lambda ()
           (when feeder
             (kill-thread feeder)
             (with-handlers ([exn:fail? void]) (close-output-port to-vm)))
           (when (eq? (subprocess-status process) 'running)
             (subprocess-kill process #t))))))

(module+ main
  (define dump? #f)
  (define dump-ir? #f)
  (define style 'plain)
  (define max-steps #f)
  (define allow-run? #f)
  (define seed #f)
  (define vm? #f)
  (define step-files '())
  (define raw-arguments
    (command-line
     #:program "agentica"
     #:once-each
     [("--version") "print the version and exit" (displayln version) (exit 0)]
     [("--vm") "run the program with the bytecode VM" (set! vm? #t)]
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
     [("--steps") path "load Agentica BDD step definitions" (set! step-files (append step-files (list path)))]
     #:args arguments
     arguments))
  (when vm?
    (define unsupported
      (or (and allow-run? "--allow-run")
          (and seed "--seed")
          (and dump? "--dump")
          (and dump-ir? "--dump-ir")
          (and (pair? step-files) "--steps")
          (and (pair? raw-arguments) (member (car raw-arguments) '("test" "help" "check" "compile"))
               (car raw-arguments))))
    (when unsupported
      (eprintf "agentica: --vm does not support ~a\n" unsupported)
      (exit 2)))
  (when (and (pair? raw-arguments) (equal? (car raw-arguments) "test"))
    (for ([argument (in-list (cdr raw-arguments))])
      (when (member argument '("--ai" "--json"))
        (set! style (if (equal? argument "--json") 'json 'ai))))
    (define (show-report report)
      (displayln (if (eq? style 'json) (jsexpr->string report)
                     (format-bdd-report report #:ai? (eq? style 'ai))))
      (exit (hash-ref report 'exit_code)))
    (define (usage-error message)
      (show-report (bdd-error-report
                    (diagnostic 'RUNTIME-BDD-USAGE message
                                (source-span (source "<arguments>" "")
                                             (source-position 0 1 1) (source-position 0 1 1))))))
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
    (define report (run-bdd (if (null? paths) '("specs/") paths) #:steps step-files #:allow-run allow-run? #:seed seed))
    (show-report report))
  (when (and (pair? raw-arguments) (equal? (car raw-arguments) "help"))
    ;; Only help consumes a trailing option; program args stay untouched.
    (when (equal? (last raw-arguments) "--json")
      (set! style 'json)
      (set! raw-arguments (drop-right raw-arguments 1)))
    (unless (= (length raw-arguments) 2)
      (eprintf "usage: agentica help NAME --json\n")
      (exit 2))
    (define name (cadr raw-arguments))
    (define entry (builtin-ref name))
    (unless entry
      (eprintf "agentica: unknown builtin ~a~a\n" name
               (let ([suggestion (did-you-mean name (hash-keys builtins))])
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
    (eprintf "usage: agentica [--version] [--vm] [--dump] [--dump-ir] [--ai|--json] [--max-steps N] [--seed N] [--allow-run] [check] <source-file> [args...]\n       agentica [--ai|--json] compile <source-file> -o <file.agcb>\n       agentica help NAME [--json]\n       agentica [--ai|--json] [--allow-run] [--seed N] test [PATH...] [--steps FILE]\n")
    (exit 2))
  (define source-file (car arguments))
  (define program-args (cdr arguments))
  (define vm (and vm? (find-vm)))
  (when (and vm (not (and (file-exists? vm) (memq 'execute (file-or-directory-permissions vm)))))
    (eprintf "agentica: cannot find the VM at ~a; run make vm or set AGENTICA_VM\n" vm)
    (exit 2))

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
  (define types (and (or compile? dump-ir? vm?) (make-hasheq)))
  (define checked (check linked #:types types))
  (when (diagnostic? checked) (fail! checked))
  (define (lowered)
    (define ir (lower checked types))
    (when (diagnostic? ir) (fail! ir))
    ir)
  (define (bytecode-data)
    (define code (ir->bytecode (lowered)))
    (when (diagnostic? code) (fail! code))
    (define data (write-bytecode code))
    (when (diagnostic? data) (fail! data))
    data)
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
    [vm?
     (define data (bytecode-data))
     (define bytecode-file (temporary-bytecode-path))
     (define created? #f)
     (define options
       (append (if max-steps (list "--max-steps" (number->string max-steps)) '())
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
     (when (eq? status 'no-temporary)
       (eprintf "agentica: cannot write a temporary file in ~a\n" (find-system-path 'temp-dir))
       (exit 2))
     (unless (exact-integer? status)
       (eprintf "agentica: cannot run the VM at ~a\n" vm)
       (exit 2))
     (exit status)]
    [else
     (define result (evaluate checked #:args program-args #:max-steps max-steps #:allow-run allow-run?
                              #:seed seed #:builtin-handler (make-bdd-service)))
     (cond
       [(diagnostic? result) (fail! result)]
       [(exit-code? result) (exit (exit-code-code result))])]))
