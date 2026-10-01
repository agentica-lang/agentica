#lang racket

(require "diagnostic.rkt"
         "lexer.rkt"
         "source.rkt"
         "token.rkt")

(module+ main
  (define source-file
    (command-line
     #:program "agentica"
     #:args (source-file)
     source-file))
  (define input (source source-file (file->string source-file)))
  (define result (lex input))
  (if (diagnostic? result)
      (begin
        (displayln (format-diagnostic result) (current-error-port))
        (exit 1))
      (for ([item (in-list result)])
        (define start (source-span-start (token-span item)))
        (printf "~a ~s @~a:~a\n"
                (token-kind item)
                (token-lexeme item)
                (source-position-line start)
                (source-position-column start)))))
