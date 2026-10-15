#lang racket

; What the tests of the Agentica front end (tests/frontend-*-test.rkt) share to run one stage, compiled from
; compiler/, over a corpus of files and compare it to the Racket stage: the temporary folder of the compiled stage,
; the run of the VM, and the reading of its output, which is one "== path" section for each file.

(require racket/runtime-path
         rackunit
         "vm-diff-common.rkt")

(provide call-with-bytecode
         output-sections
         run-stage-sections
         agc-files-under)

(define-runtime-path root "..")

; Compiles the entry program with compile (compile-file of vm-diff-common.rkt) into a temporary folder, calls
; (proc folder bytecode-path) and deletes the folder.
(define (call-with-bytecode compile entry proc)
  (define work (make-temporary-directory "agentica-frontend~a"))
  (dynamic-wind
    void
    (lambda ()
      (define bytecode (build-path work "entry.agcb"))
      (compile entry bytecode)
      (proc work bytecode))
    (lambda () (delete-directory/files work))))

; The text of each section of the output of a stage, by the path on its "== path" line. The text keeps the final
; newline.
(define (output-sections out)
  (for/hash ([piece (in-list (cdr (regexp-split #rx"(?m:^== )" out)))])
    (define newline-at (let loop ([at 0]) (if (char=? (string-ref piece at) #\newline) at (loop (add1 at)))))
    (values (substring piece 0 newline-at) (substring piece (add1 newline-at)))))

; Runs the stage once from the root of the repository: the VM with the flags, then `--`, the bytecode of the stage
; and its arguments. The run must exit 0 and print nothing on stderr. Gives the sections of its output.
(define (run-stage-sections bytecode arguments #:flags [flags '()] #:timeout [timeout run-timeout])
  (define result
    (parameterize ([current-directory root])
      (apply run-process vm-file #:timeout timeout (append flags (list "--" (path->string bytecode)) arguments))))
  (check-equal? (first result) 0 (third result))
  (check-equal? (third result) "")
  (output-sections (second result)))

; The .agc files under the directories (relative to the root of the repository) for which keep? is true, as paths
; relative to the root, sorted.
(define (agc-files-under directories #:keep? [keep? (lambda (file) #t)])
  (define base (simplify-path root))
  (sort (for*/list ([directory (in-list directories)]
                    [file (in-directory (build-path base directory))]
                    #:when (and (path-has-extension? file #".agc") (keep? file)))
          (path->string (find-relative-path base (simplify-path file))))
        string<?))
