#lang racket

; Freezes the live comparisons of tests/frontend-check-test.rkt: the Racket checker over the programs of
; tests/checker-test.rkt, 1,500 mutants of them, the corpus, every std/ module and the compiler, trees around the nesting
; limit and a program of 1,000 functions. tests/test_frontend_check.py compares the Agentica checker with what is written
; here. Run by `make frontend-freeze`. The inputs that are a formula are rebuilt by the Python test; the manifests hold
; their hashes.

(require "frontend-freeze-common.rkt"
         "frontend-check-common.rkt"
         (prefix-in test: "frontend-check-test.rkt"))

(define (output-of path) (string-append (check-text path) "\n"))

(define (write-programs)
  (define programs (read-frozen-json "corpus/checker-programs.json"))
  (call-with-temporary-folder
   (lambda (dir)
     (write-manifest "check/programs.sha256" (program-entries dir "cases" (numbered "c" programs) output-of))
     (define mutants (test:mutated-programs programs 1500))
     (write-frozen-json "check/mutated.json" mutants)
     (define entries (program-entries dir "mutated" (numbered "m" mutants) output-of))
     ;; The Python test asserts that more than 150 mutants reach the checker.
     (printf "check mutated: ~a of ~a reach the checker\n"
             (count (lambda (entry) (not (regexp-match? #rx"^ERROR (PARSE|LEX)-" (second entry)))) entries)
             (length entries))
     (write-manifest "check/mutated.sha256" entries))))

(define (write-corpus)
  (with-corpus
    (lambda (dir)
      (define files (corpus-paths))
      (define (path-entries keys)
        (for/list ([key (in-list keys)])
          (list key (output-of (path->string (build-path dir key))) (hash-ref files key))))
      (write-manifest "check/corpus.sha256"
                      (path-entries (append (direct-files files "examples") (direct-files files "tests/fixtures/vm"))))
      (write-manifest "check/std-compiler.sha256"
                      (append (program-entries dir "std" (std-wrappers files) output-of)
                              (path-entries (direct-files files "compiler")))))))

(define (write-deep)
  (call-with-temporary-folder
   (lambda (dir)
     (write-manifest "check/deep.sha256"
                     (program-entries dir "deep" (for/list ([entry (in-list (test:deep-cases))])
                                                   (cons (format "deep-~a" (car entry)) (cdr entry)))
                                output-of)))))

(define (write-generated)
  (call-with-temporary-folder
   (lambda (dir)
     (write-manifest "check/generated.sha256"
                     (program-entries dir "generated" (list (cons "generated" (test:generated-program 1000))) output-of)))))

(module+ main
  (write-programs)
  (write-corpus)
  (write-deep)
  (write-generated))
