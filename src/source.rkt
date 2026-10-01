#lang racket

(provide (struct-out source)
         (struct-out source-position)
         (struct-out source-span))

(struct source (name text) #:transparent)
(struct source-position (offset line column) #:transparent)
(struct source-span (source start end) #:transparent)
