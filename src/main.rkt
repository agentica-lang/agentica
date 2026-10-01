#lang racket

(require "diagnostic.rkt"
         "lexer.rkt"
         "parser.rkt"
         "source.rkt")

(module+ main
  (define source-file
    (command-line
     #:program "agentica"
     #:args (source-file)
     source-file))
  (define input (source source-file (file->string source-file)))
  (define result (lex input))
  (cond
    [(diagnostic? result)
     (displayln (format-diagnostic result) (current-error-port))
     (exit 1)]
    [else
     (define tree (parse result))
     (if (diagnostic? tree)
         (begin
           (displayln (format-diagnostic tree) (current-error-port))
           (exit 1))
         (pretty-print tree))]))
