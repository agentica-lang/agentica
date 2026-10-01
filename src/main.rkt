#lang racket

(require "checker.rkt"
         "diagnostic.rkt"
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

  (define (fail! problem)
    (displayln (format-diagnostic problem) (current-error-port))
    (exit 1))

  (define lexed (lex input))
  (when (diagnostic? lexed) (fail! lexed))
  (define tree (parse lexed))
  (when (diagnostic? tree) (fail! tree))
  (define checked (check tree))
  (when (diagnostic? checked) (fail! checked))
  (pretty-print checked))
