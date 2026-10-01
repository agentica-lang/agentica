#lang racket

(require "source.rkt")

(provide (struct-out diagnostic)
         format-diagnostic)

(struct diagnostic (code message span) #:transparent)

(define (format-diagnostic problem)
  (define start (source-span-start (diagnostic-span problem)))
  (format "~a:~a:~a: [~a] ~a"
          (source-name (source-span-source (diagnostic-span problem)))
          (source-position-line start)
          (source-position-column start)
          (diagnostic-code problem)
          (diagnostic-message problem)))
