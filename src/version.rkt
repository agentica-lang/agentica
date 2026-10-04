#lang racket

;; Single source of truth for the released version. Keep it in sync with
;; CHANGELOG.md and the Git tag; the release workflow validates the tag against
;; this value.
(provide version)

(define version "0.1.0")
