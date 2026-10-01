#lang racket

(provide (struct-out source)
         (struct-out source-position)
         (struct-out source-span))

;; Opaque so a printed tree shows #<source> instead of the whole file text.
(struct source (name text))
(struct source-position (offset line column) #:transparent)
(struct source-span (source start end) #:transparent)
