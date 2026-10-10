#lang racket

(require json
         "bdd-runner.rkt"
         "builtins.rkt"
         "checker.rkt"
         "diagnostic.rkt"
         "evaluator.rkt"
         "lexer.rkt"
         "parser.rkt"
         "modules.rkt"
         "source.rkt"
         "version.rkt")

(module+ main
  (define dump? #f)
  (define style 'plain)
  (define max-steps #f)
  (define allow-run? #f)
  (define seed #f)
  (define step-files '())
  (define raw-arguments
    (command-line
     #:program "agentica"
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
     [("--ai") "print diagnostics as compact text for an agent" (set! style 'ai)]
     [("--json") "print diagnostics as one JSON object" (set! style 'json)]
     #:multi
     [("--steps") path "load Agentica BDD step definitions" (set! step-files (append step-files (list path)))]
     #:args arguments
     arguments))
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
    (define report (run-bdd (if (null? paths) '("specs/") paths) #:steps step-files #:allow-run allow-run?))
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
  (define arguments (if check-only? (cdr raw-arguments) raw-arguments))
  (unless (>= (length arguments) 1)
    (eprintf "usage: agentica [--version] [--dump] [--ai|--json] [--max-steps N] [--seed N] [--allow-run] [check] <source-file> [args...]\n       agentica help NAME [--json]\n       agentica [--ai|--json] [--allow-run] test [PATH...] [--steps FILE]\n")
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
  (define checked (check linked))
  (when (diagnostic? checked) (fail! checked))
  (cond
    [check-only? (displayln (if (eq? style 'json) "{\"ok\":true}" "check ok"))]
    [dump? (pretty-print checked)]
    [else
     (define result (evaluate checked #:args program-args #:max-steps max-steps #:allow-run allow-run?
                              #:seed seed #:builtin-handler (make-bdd-service)))
     (cond
       [(diagnostic? result) (fail! result)]
       [(exit-code? result) (exit (exit-code-code result))])]))
