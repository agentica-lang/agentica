#lang racket

; Writes the snapshot of the corpus that the frozen comparisons run on (tests/frontend-freeze-common.rkt): the .agc
; files of examples/, stdlib/, tests/fixtures/ (without the linker fixtures) and compiler/ as they are now, the programs of
; the cases of tests/checker-test.rkt and the programs in the code blocks of the site. Run it once, when a freeze is
; made (`make frontend-snapshot`); the stage writers then read the snapshot, never those folders, so the freeze does not
; move when they change.

(require racket/runtime-path
         "frontend-freeze-common.rkt"
         (only-in "frontend-check-test.rkt" checker-case-programs)
         (only-in "frontend-modules-test.rkt" site-programs))

(define (agc-files directory #:recursive? [recursive? #t] #:skip [skip '()])
  (define base (simplify-path (build-path repo-root directory)))
  (sort (for/list ([file (in-list (if recursive?
                                      (sequence->list (in-directory base))
                                      (map (lambda (name) (build-path base name)) (directory-list base))))]
                   #:when (and (file-exists? file)
                               (not (link-exists? file))
                               (path-has-extension? file #".agc")
                               (not (for/or ([part (in-list skip)]) (string-contains? (path->string file) part)))))
          (path->string (find-relative-path (simplify-path repo-root) (simplify-path file))))
        string<?))

(define (write-corpus name directory #:recursive? [recursive? #t] #:skip [skip '()])
  (define files (agc-files directory #:recursive? recursive? #:skip skip))
  (define table
    (for/hash ([path (in-list files)])
      (values (string->symbol path) (file->string (build-path repo-root path)))))
  (write-frozen-json (format "corpus/~a.json" name) table)
  (printf "corpus/~a.json: ~a files\n" name (length files)))

(module+ main
  (write-corpus "examples" "examples")
  (write-corpus "stdlib" "stdlib")
  (write-corpus "fixtures" "tests/fixtures" #:skip '("/frontend/modules/" "/frontend/frozen/"))
  (write-corpus "compiler" "compiler" #:recursive? #f)
  (define programs (checker-case-programs))
  (write-frozen-json "corpus/checker-programs.json" programs)
  (printf "corpus/checker-programs.json: ~a programs\n" (length programs))
  (define site (site-programs))
  (write-frozen-json "corpus/site-programs.json" site)
  (printf "corpus/site-programs.json: ~a programs\n" (length site)))
