#lang racket

(module+ main
  (define source-file
    (command-line
     #:program "agentica"
     #:args (source-file)
     source-file))
  (define source (file->string source-file))
  (printf "Loaded ~a (~a characters); Agentica interpretation is not implemented yet.\n"
          source-file
          (string-length source)))
