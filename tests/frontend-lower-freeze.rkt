#lang racket

; Freezes the live comparisons of tests/frontend-lower-test.rkt: the Racket lowering over the corpus, the programs of
; tests/checker-test.rkt, every std/ module, the compiler, trees at the nesting limit and a program of 300 functions.
; tests/test_frontend_lower.py compares the Agentica lowering with what is written here. Run by `make frontend-freeze`.
; The inputs that are a formula are rebuilt by the Python test; the manifests hold their hashes.

(require (only-in "frontend-lower-common.rkt" lower-text deep-cases generated-program)
         (only-in "../src/lower.rkt" vm-builtins)
         "frontend-freeze-common.rkt")

(define (output-of path) (string-append (lower-text path) "\n"))

(define (write-corpus)
  (with-corpus
    (lambda (dir)
      (define files (corpus-paths))
      (define (path-entries keys)
        (for/list ([key (in-list keys)])
          (list key (output-of (path->string (build-path dir key))) (hash-ref files key))))
      (write-manifest "lower/examples.sha256" (path-entries (direct-files files "examples")))
      (write-manifest "lower/vm.sha256" (path-entries (direct-files files "tests/fixtures/vm")))
      (write-manifest "lower/std-compiler.sha256"
                      (append (program-entries dir "std" (std-wrappers files) output-of)
                              (path-entries (direct-files files "compiler")))))))

(define (write-programs)
  (define programs (read-frozen-json "corpus/checker-programs.json"))
  (call-with-temporary-folder
   (lambda (dir)
     (write-manifest "lower/programs.sha256" (program-entries dir "cases" (numbered "c" programs) output-of)))))

(define (write-deep)
  (call-with-temporary-folder
   (lambda (dir)
     (write-manifest "lower/deep.sha256"
                     (program-entries dir "deep" (for/list ([entry (in-list (deep-cases))])
                                                   (cons (format "deep-~a" (car entry)) (cdr entry)))
                                      output-of)))))

(define (write-generated)
  (call-with-temporary-folder
   (lambda (dir)
     (write-manifest "lower/generated.sha256"
                     (program-entries dir "generated" (list (cons "generated" (generated-program 300))) output-of)))))

;; The builtins the Racket lowering sends to the VM, which VM_BUILTINS of compiler/lower_tables.agc must list.
(define (write-vm-builtins)
  (write-frozen "lower/vm-builtins.expected"
                (string-append* (for/list ([name (in-list (sort vm-builtins string<?))]) (string-append name "\n"))))
  (printf "lower/vm-builtins.expected\n"))

(module+ main
  (write-vm-builtins)
  (write-corpus)
  (write-programs)
  (write-deep)
  (write-generated))
