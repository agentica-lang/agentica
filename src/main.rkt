#lang racket

(require json
         "builtins.rkt"
         "checker.rkt"
         "diagnostic.rkt"
         "evaluator.rkt"
         "lexer.rkt"
         "parser.rkt"
         "source.rkt")

(module+ main
  (define dump? #f)
  (define style 'plain)
  (define max-steps #f)
  (define raw-arguments
    (command-line
     #:program "agentica"
     #:once-each
     [("--max-steps") count "limit execution to N expression/statement entries"
      (define parsed (string->number count))
      (unless (and (regexp-match? #px"^[0-9]+$" count) (exact-positive-integer? parsed))
        (eprintf "agentica: --max-steps needs a positive integer\n")
        (exit 2))
      (set! max-steps parsed)]
     [("--dump") "print the checked tree instead of running it" (set! dump? #t)]
     [("--ai") "print diagnostics as compact text for an agent" (set! style 'ai)]
     [("--json") "print diagnostics as one JSON object" (set! style 'json)]
     #:args arguments
     arguments))
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
    (eprintf "usage: agentica [--dump] [--ai|--json] [--max-steps N] [check] <source-file> [args...]\n       agentica help NAME [--json]\n")
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
  (define checked (check tree))
  (when (diagnostic? checked) (fail! checked))
  (cond
    [check-only? (displayln (if (eq? style 'json) "{\"ok\":true}" "check ok"))]
    [dump? (pretty-print checked)]
    [else
     (define result (evaluate checked #:args program-args #:max-steps max-steps))
     (cond
       [(diagnostic? result) (fail! result)]
       [(exit-code? result) (exit (exit-code-code result))])]))
