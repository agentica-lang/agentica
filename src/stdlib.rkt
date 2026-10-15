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
        "std/logger.agc" (embed-source "logger.agc")
        "std/binary.agc" (embed-source "binary.agc")
        "std/toml.agc" (embed-source "toml.agc")
        "std/bdd.agc" (embed-source "bdd.agc")
        "std/bdd/gherkin.agc" (embed-source "bdd/gherkin.agc")
        "std/bdd/match.agc" (embed-source "bdd/match.agc")
        "std/test/report.agc" (embed-source "test/report.agc")
        "std/test/child.agc" (embed-source "test/child.agc")
        "std/test/units.agc" (embed-source "test/units.agc")
        "std/test/runner.agc" (embed-source "test/runner.agc")))
