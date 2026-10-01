#lang racket

(require "checker.rkt"
         "diagnostic.rkt"
         "evaluator.rkt"
         "lexer.rkt"
         "parser.rkt"
         "source.rkt")

(module+ main
  (define dump? #f)
  (define arguments
    (command-line
     #:program "agentica"
     #:once-each
     [("--dump") "print the checked tree instead of running it" (set! dump? #t)]
     #:args arguments
     arguments))
  (unless (= (length arguments) 1)
    (eprintf "usage: agentica [--dump] <source-file>\n")
    (exit 2))
  (define source-file (car arguments))

  (define (fail! problem)
    (displayln (format-diagnostic problem) (current-error-port))
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
    [dump? (pretty-print checked)]
    [else
     (define result (evaluate checked))
     (when (diagnostic? result) (fail! result))]))
