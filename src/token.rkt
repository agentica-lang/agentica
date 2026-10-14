#lang racket

(require "source.rkt")

(provide (struct-out token)
         (struct-out doc-block))

(struct token (kind lexeme value span) #:transparent)
(struct doc-block (text next) #:transparent)
