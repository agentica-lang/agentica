#lang racket

(require "source.rkt")

(provide (struct-out token))

(struct token (kind lexeme value span) #:transparent)
