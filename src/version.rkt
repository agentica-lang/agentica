#lang racket/base

;; The released version, read from the VERSION file at the repository root when this module is compiled, so a
;; compiled program (raco exe, raco distribute) carries it and needs no file at run time. VERSION is the single
;; source: the Makefile (AGC_VERSION for the VM, `make version`) reads the same file. Keep it in sync with
;; CHANGELOG.md and the Git tag; the release workflow validates the tag against it.
(require (for-syntax racket/base racket/file racket/string compiler/cm-accomplice))

(provide version)

(define-syntax (embedded-version stx)
  (define source (syntax-source stx))
  (define-values (folder _name _dir?) (split-path source))
  (define file (simplify-path (build-path folder 'up "VERSION")))
  ;; raco make then compiles this module again when VERSION changes.
  (register-external-file file)
  (datum->syntax stx (string-trim (file->string file))))

(define version (embedded-version))
