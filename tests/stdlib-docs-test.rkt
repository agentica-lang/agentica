#lang racket

(require rackunit
         racket/runtime-path
         "../src/ast.rkt"
         "../src/diagnostic.rkt"
         "../src/lexer.rkt"
         "../src/parser.rkt"
         "../src/source.rkt")

(define-runtime-path stdlib-directory "../stdlib")

(define (stdlib-files)
  (sort (for/list ([file (in-directory stdlib-directory)]
                   #:when (path-has-extension? file #".agc"))
          file)
        path<?))

(define (parse-file file)
  (define name (path->string file))
  (define tokens (lex (source name (file->string file))))
  (if (diagnostic? tokens) tokens (parse tokens)))

(module+ test
  (test-case "the standard library has files to check"
    (check-true (>= (length (stdlib-files)) 9)))

  (for ([file (in-list (stdlib-files))])
    (define name (path->string (find-relative-path (simplify-path stdlib-directory) (simplify-path file))))
    (test-case (format "~a has a module doc and a doc on every export" name)
      (define program (parse-file file))
      (check-false (diagnostic? program) (if (diagnostic? program) (format-diagnostic program) name))
      (when (program? program)
        (check-pred string? (program-module-doc program) (format "~a: module doc" name))
        (check-not-equal? (string-trim (or (program-module-doc program) "")) "" (format "~a: module doc" name))
        (for ([declaration (in-list (program-declarations program))] #:when (export-decl? declaration))
          (define inner (export-decl-declaration declaration))
          (define documented (hash-ref (program-docs program) (node-span declaration) #f))
          (check-pred string? documented
                      (format "~a: line ~a" name (source-position-line (source-span-start (node-span inner)))))
          (check-not-equal? (string-trim (or documented "")) ""
                            (format "~a: line ~a" name (source-position-line (source-span-start (node-span inner))))))))))
