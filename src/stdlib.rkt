#lang racket/base

(require (for-syntax racket/base racket/file racket/list racket/path compiler/cm-accomplice))
(provide stdlib-sources)

;; The std/ modules are the paths listed in stdlib/MODULES, one per line and relative to stdlib/. The Makefile embeds
;; the same list in the single binary. Read at compile time, not at executable startup. The list and every source are
;; tracked, so raco make rebuilds this module whenever the Agentica library changes.
(define-syntax (embed-stdlib stx)
  (syntax-case stx ()
    [(_)
     (let* ([root (build-path (path-only (syntax-source stx)) ".." "stdlib")]
            [index (build-path root "MODULES")])
       (register-external-file index)
       (datum->syntax
        stx
        (cons 'hash
              (append*
               (for/list ([name (in-list (file->lines index))] #:unless (string=? name ""))
                 (define path (build-path root name))
                 (register-external-file path)
                 (list (string-append "std/" name) (file->string path)))))))]))

;; Explicit registry: only shipped modules are available through std/.
(define stdlib-sources (embed-stdlib))
