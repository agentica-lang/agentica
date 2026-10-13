#lang racket/base

(require (for-syntax racket/base racket/file racket/path compiler/cm-accomplice))
(provide stdlib-sources)

;; Read at compile time, not at executable startup. Track the source dependency
;; so raco make rebuilds this module whenever the Agentica library changes.
(define-syntax (embed-source stx)
  (syntax-case stx ()
    [(_ name)
     (let ([path (build-path (path-only (syntax-source stx)) ".." "stdlib"
                             (syntax-e #'name))])
       (register-external-file path)
       (datum->syntax stx (file->string path)))]))

;; Explicit registry: only shipped modules are available through std/.
(define stdlib-sources
  (hash "std/queue.agc" (embed-source "queue.agc")
        "std/http.agc" (embed-source "http.agc")
        "std/bdd/gherkin.agc" (embed-source "bdd/gherkin.agc")
        "std/bdd/match.agc" (embed-source "bdd/match.agc")))
