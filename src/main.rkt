#lang racket

(require json
         "checker.rkt"
         "diagnostic.rkt"
         "evaluator.rkt"
         "lexer.rkt"
         "parser.rkt"
         "source.rkt")

(module+ main
  (define dump? #f)
  (define style 'plain)
  (define raw-arguments
    (command-line
     #:program "agentica"
     #:once-each
     [("--dump") "print the checked tree instead of running it" (set! dump? #t)]
     [("--ai") "print diagnostics as compact text for an agent" (set! style 'ai)]
     [("--json") "print diagnostics as one JSON object" (set! style 'json)]
     #:args arguments
     arguments))
  (define check-only? (and (pair? raw-arguments) (equal? (car raw-arguments) "check")))
  (define arguments (if check-only? (cdr raw-arguments) raw-arguments))
  (unless (>= (length arguments) 1)
    (eprintf "usage: agentica [--dump] [--ai|--json] [check] <source-file> [args...]\n")
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
     (define result (evaluate checked #:args program-args))
     (cond
       [(diagnostic? result) (fail! result)]
       [(exit-code? result) (exit (exit-code-code result))])]))
