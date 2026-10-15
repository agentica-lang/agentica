#lang racket

; Freezes the live comparisons of tests/frontend-modules-test.rkt: the Racket linker over the corpus, the programs of
; the site, 300 mutated fixtures, long chains of files, deep trees, files that are not UTF-8 or over 1 MiB, and the
; number of node ids each file takes. tests/test_frontend_modules.py compares the Agentica linker with what is written
; here. Run by `make frontend-freeze`. The inputs that are a formula are rebuilt by the Python test; the manifests hold
; their hashes.

(require racket/runtime-path
         "frontend-freeze-common.rkt"
         "frontend-modules-common.rkt"
         "../src/diagnostic.rkt"
         "../src/modules.rkt"
         (only-in "../src/stdlib.rkt" stdlib-sources)
         (prefix-in test: "frontend-modules-test.rkt"))

(define-runtime-path fixtures "fixtures/frontend/modules")

(define (output-of text) (string-append text "\n"))

(define (repeat text count) (string-append* (make-list count text)))

(define (function-body body) (string-append "def main() -> Void\n" body "end\n\n"))

;; The text of linking the root file of a tree written below dir.
(define (link-tree dir root-name [env default-env])
  (output-of (link-text (path->string (build-path dir root-name)) #:env env)))

;; The names and node counts of the files a link reads, one line each in name order: what the id ranges of
;; `link.agc --ids` must add up to. The names are those of the text form.
(define (sizes-text root-path env)
  (with-env env
    (lambda ()
      (define folder (root-folder root-path))
      (define files (box '()))
      (define linked (load-program root-path #:files files))
      (when (diagnostic? linked) (error 'sizes-text "~a does not link" root-path))
      (define names (unbox files))
      (define sizes (module-sizes names))
      (string-append*
       (for/list ([entry (in-list (sort (for/list ([size (in-list sizes)])
                                          (cons (display-path folder (car size)) (cdr size)))
                                        string<? #:key car))])
         (format "~a ~a\n" (car entry) (cdr entry)))))))

;; The output a deep case freezes: the ERROR line when the file does not link, else its sizes.
(define (deep-output root-path)
  (define text (link-text root-path))
  (if (string-prefix? text "ERROR")
      (output-of text)
      (sizes-text root-path default-env)))

;; The files of a folder as (path . bytes), without links and without going through them: the fixtures keep their links in
;; fixture.links and a case made from one has them made again.
(define (tree-files base)
  (let walk ([dir base] [prefix ""])
    (append*
     (for/list ([name (in-list (directory-list dir))])
       (define path (build-path dir name))
       (define relative (string-append prefix (path->string name)))
       (cond
         [(link-exists? path) '()]
         [(directory-exists? path) (walk path (string-append relative "/"))]
         [else (list (cons relative (file->bytes path)))])))))

(define (fixture-files name) (tree-files (build-path fixtures name)))

(define (write-corpus)
  (with-corpus
    (lambda (dir)
      (define keys (sort (filter (lambda (path) (not (string-prefix? path "compiler/"))) (hash-keys (corpus-paths))) string<?))
      (parameterize ([current-directory dir])
        (write-manifest "modules/corpus.sha256"
                        (for/list ([key (in-list keys)])
                          (list key (output-of (link-text key)) (hash-ref (corpus-paths) key))))))))

;; The id ranges: the sizes of the files of six fixtures.
(define (write-ids)
  (define names '("diamond" "empty-modules" "every-node" "pkg-environment-first" "canonical-identities" "bdd-steps"))
  (define inputs (filter (lambda (input) (member (module-input-name input) names)) (module-inputs)))
  (write-manifest "modules/ids.sha256"
                  (for/list ([input (in-list inputs)])
                    (list (format "ids-~a" (module-input-name input))
                          (sizes-text (module-input-root input) (module-input-env input))
                          (tree-listing (fixture-files (module-input-name input)))))))

(define (write-above-and-symlink)
  (define root-text "import Shared from \"../shared/x\"\n\ndef main() -> Void\n  puts(Shared.name())\nend\n")
  (define shared-text "export def name() -> String\n  return \"x\"\nend\n")
  (call-with-temporary-folder
   (lambda (dir)
     (write-tree dir (list (cons "above/app/root.agc" root-text) (cons "above/shared/x.agc" shared-text)))
     (write-frozen "modules/above.expected" (link-tree dir "above/app/root.agc"))
     (write-tree dir (list (cons "linked/real/app/root.agc" root-text) (cons "linked/real/shared/x.agc" shared-text)))
     (make-file-or-directory-link (build-path "real" "app") (build-path dir "linked" "linkapp"))
     (write-frozen "modules/symlink.expected" (link-tree dir "linked/linkapp/root.agc"))
     (printf "modules/above.expected, modules/symlink.expected\n"))))

(define (write-invalid-utf8)
  (define import-root "import Bad from \"./bad\"\n\ndef main() -> Void\nend\n")
  (call-with-temporary-folder
   (lambda (dir)
     (write-manifest
      "modules/invalid-utf8.sha256"
      (append*
       (for/list ([entry (in-list test:invalid-utf8-cases)] [n (in-naturals)])
         (define content (bytes-append (second entry) (third entry) (fourth entry)))
         (define alone (list (cons "root.agc" content)))
         (define imported (list (cons "root.agc" import-root) (cons "bad.agc" content)))
         (write-tree dir (map (lambda (file) (cons (format "root-~a/~a" n (car file)) (cdr file))) alone))
         (write-tree dir (map (lambda (file) (cons (format "import-~a/~a" n (car file)) (cdr file))) imported))
         (list (list (format "utf8-~a-root" n) (link-tree dir (format "root-~a/root.agc" n)) (tree-listing alone))
               (list (format "utf8-~a-import" n) (link-tree dir (format "import-~a/root.agc" n)) (tree-listing imported)))))))))

(define (write-unreadable-import)
  (call-with-temporary-folder
   (lambda (dir)
     (write-tree dir (list (cons "root.agc" "import Bad from \"./bad\"\n\ndef main() -> Void\nend\n")))
     (make-directory* (build-path dir "bad.agc"))
     (write-frozen "modules/unreadable-import.expected" (link-tree dir "root.agc"))
     (printf "modules/unreadable-import.expected\n"))))

(define (write-big)
  (define comment (test:big-comment))
  (define program #"def main() -> Void\n  puts(\"big\")\nend\n")
  (define alone (list (cons "root.agc" (bytes-append comment program))))
  (define imported
    (list (cons "big.agc" (bytes-append comment #"export def one() -> Int\n  return 1\nend\n"))
          (cons "root.agc" "import Big from \"./big\"\n\ndef main() -> Void\n  puts(Big.one().to_s)\nend\n")))
  (call-with-temporary-folder
   (lambda (dir)
     (write-tree dir (map (lambda (file) (cons (string-append "alone/" (car file)) (cdr file))) alone))
     (write-tree dir (map (lambda (file) (cons (string-append "imported/" (car file)) (cdr file))) imported))
     (write-manifest "modules/big.sha256"
                     (list (list "big-alone" (link-tree dir "alone/root.agc") (tree-listing alone))
                           (list "big-imported" (link-tree dir "imported/root.agc") (tree-listing imported)))))))

(define (write-site)
  (define programs (read-frozen-json "corpus/site-programs.json"))
  (call-with-temporary-folder
   (lambda (dir)
     (write-manifest "modules/site.sha256"
                     (for/list ([text (in-list programs)] [n (in-naturals)])
                       (define name (format "site/block-~a.agc" n))
                       (write-tree dir (list (cons name text)))
                       (list (format "site-~a" n) (link-tree dir name) text))))))

;; The cases are the fixtures with one or two files changed. A case is kept as the name of its fixture and the files
;; that changed, so it is small; the Python test copies the fixture, makes its links and writes those files.
(define (write-mutated)
  (define fixture-names
    (for/list ([entry (in-list (directory-list fixtures))] #:when (directory-exists? (build-path fixtures entry)))
      (path->string entry)))
  (define bases (for/hash ([name (in-list fixture-names)]) (values name (make-immutable-hash (fixture-files name)))))
  (call-with-temporary-folder
   (lambda (dir)
     (define targets (test:mutated-fixtures dir 300))
     (define cases
       (for/list ([target (in-list targets)])
         (define files (make-immutable-hash (tree-files target)))
         (define-values (name changed)
           (for/fold ([best-name #f] [best-changed #f]) ([name (in-list fixture-names)])
             (define base (hash-ref bases name))
             (cond
               [(equal? (sort (hash-keys base) string<?) (sort (hash-keys files) string<?))
                (define changed (for/list ([(path content) (in-hash files)] #:unless (equal? content (hash-ref base path))) path))
                (if (or (not best-changed) (< (length changed) (length best-changed)))
                    (values name changed)
                    (values best-name best-changed))]
               [else (values best-name best-changed)])))
         (unless (and name (<= (length changed) 2)) (error 'write-mutated "no fixture matches ~a" target))
         (list name target (for/list ([path (in-list (sort changed string<?))]) (cons path (hash-ref files path))))))
     (write-frozen-json "modules/mutated.json"
                        (for/list ([entry (in-list cases)])
                          (hasheq 'fixture (first entry)
                                  'files (for/hasheq ([file (in-list (third entry))])
                                           (values (string->symbol (car file)) (bytes->string/utf-8 (cdr file)))))))
     (define entries
                       (for/list ([entry (in-list cases)] [n (in-naturals)])
                       (define merged
                         (for/fold ([base (hash-ref bases (first entry))]) ([file (in-list (third entry))])
                           (hash-set base (car file) (cdr file))))
                       (list (format "case-~a" n)
                             (link-tree (second entry) "root.agc")
                             (tree-listing (hash->list merged)))))
     ;; The Python test asserts that the mutants are neither all errors nor all programs.
     (printf "modules mutated: ~a of ~a are errors\n"
             (count (lambda (entry) (string-prefix? (second entry) "ERROR")) entries) (length entries))
     (write-manifest "modules/mutated.sha256" entries))))

;; Long chains of files: a chain of 3000 files, a file that imports 2000, a cycle of 1500 and a failure at the end of a
;; chain of 1500. The two first also have their id ranges frozen.
(define (chain-files)
  (for/list ([n (in-range 3000)])
    (cons (format "chain/m~a.agc" n)
          (if (< n 2999)
              (format "import Next from \"m~a\"\nexport def f~a() -> Int\n  return Next.f~a()\nend\n\n" (add1 n) n (add1 n))
              (format "export def f~a() -> Int\n  return 1\nend\n\n" n)))))

(define (wide-files)
  (append (for/list ([n (in-range 2000)])
            (cons (format "wide/w~a.agc" n) (format "export def g~a() -> Int\n  return ~a\nend\n\n" n n)))
          (list (cons "wide/root.agc"
                      (string-append (string-append* (for/list ([n (in-range 2000)]) (format "import W~a from \"w~a\"\n" n n)))
                                     "def main() -> Void\n  puts(W0.g0())\nend\n\n")))))

(define (cycle-files)
  (for/list ([n (in-range 1500)])
    (cons (format "cycle/c~a.agc" n) (format "import Next from \"c~a\"\n" (modulo (add1 n) 1500)))))

(define (broken-files)
  (for/list ([n (in-range 1500)])
    (cons (format "broken/b~a.agc" n)
          (if (< n 1499)
              (format "import Next from \"b~a\"\nexport def f() -> Int\n  return Next.f()\nend\n\n" (add1 n))
              "export def f() -> Int\n  return Nope.Thing\nend\n\n"))))

(define (write-large)
  (define sets (list (list "chain" (chain-files) "chain/m0.agc")
                     (list "wide" (wide-files) "wide/root.agc")
                     (list "cycle" (cycle-files) "cycle/c0.agc")
                     (list "broken" (broken-files) "broken/b0.agc")))
  (call-with-temporary-folder
   (lambda (dir)
     (for ([set (in-list sets)]) (write-tree dir (second set)))
     (write-manifest "modules/large.sha256"
                     (for/list ([set (in-list sets)])
                       (list (first set) (link-tree dir (third set)) (tree-listing (second set)))))
     (write-manifest "modules/large-ids.sha256"
                     (for/list ([set (in-list sets)] #:when (member (first set) '("chain" "wide")))
                       (list (string-append (first set) "-ids")
                             (sizes-text (path->string (build-path dir (third set))) default-env)
                             (tree-listing (second set))))))))

(define (nested-chains k l)
  (for/fold ([text "x"]) ([_ (in-range k)])
    (string-append "x + (" text ")" (repeat " + x" l))))

;; Trees as deep as the parser allows. Each ends in a name that the linker refuses (Nope.Thing), so that the
;; diagnostic shows the walk reached the deepest node, and the legal variants are frozen by their id ranges.
(define (deep-files)
  (define (bad-then text) (function-body (string-append "  y = " text "\n")))
  (list
   (cons "chain-ok" (bad-then (string-append "x" (repeat " + x" 998))))
   (cons "chain-bad" (bad-then (string-append "Nope.Thing" (repeat " + x" 998))))
   (cons "method-bad" (bad-then (string-append "Nope.Thing" (repeat ".f(1)" 997))))
   (cons "nested-chains-ok" (bad-then (string-append "x + (x + (x + (x" (repeat " + x" 400) ")))")))
   (cons "nested-chains-bad" (bad-then (string-append "x + (x + (x + (Nope.Thing" (repeat " + x" 400) ")))")))
   (cons "nested-chains-deep-ok" (bad-then (nested-chains 8 900)))
   (cons "nested-chains-limit-ok" (bad-then (nested-chains 11 900)))
   (cons "nested-chains-deep-bad" (bad-then (string-append "Nope.Thing + (" (nested-chains 7 900) ")" (repeat " + x" 900))))
   (cons "calls-bad" (bad-then (string-append (repeat "f(" 900) "Nope.Thing" (repeat ")" 900))))
   (cons "lists-bad" (bad-then (string-append (repeat "[" 990) "Nope.Thing" (repeat "]" 990))))
   (cons "types-bad" (string-append "def f(a: " (repeat "List[" 900) "Nope.Thing" (repeat "]" 900) ") -> Void\nend\n\n"))
   (cons "ifs-bad" (function-body (string-append (repeat "  if x\n" 400) "  y = Nope.Thing\n" (repeat "  end\n" 400))))))

(define (write-deep)
  (call-with-temporary-folder
   (lambda (dir)
     (write-manifest "modules/deep.sha256"
                     (for/list ([entry (in-list (deep-files))])
                       (define name (format "deep/~a.agc" (car entry)))
                       (write-tree dir (list (cons name (cdr entry))))
                       (list (format "deep-~a" (car entry))
                             (deep-output (path->string (build-path dir name)))
                             (cdr entry)))))))

(define (write-flat)
  (define text
    (string-append* (for/list ([n (in-range 2000)])
                      (format "def f~a(a: Int) -> Int\n  return a + ~a\nend\n\n" n n))))
  (call-with-temporary-folder
   (lambda (dir)
     (write-tree dir (list (cons "flat.agc" text)))
     (write-manifest "modules/flat.sha256" (list (list "flat" (link-tree dir "flat.agc") text))))))

;; The std/ modules the Racket front end embeds, which stdlib/ must hold exactly.
(define (write-registry)
  (write-frozen "modules/stdlib-registry.expected"
                (string-append* (for/list ([name (in-list (sort (hash-keys stdlib-sources) string<?))])
                                  (string-append name "\n"))))
  (printf "modules/stdlib-registry.expected\n"))

(module+ main
  (write-registry)
  (write-ids)
  (write-above-and-symlink)
  (write-invalid-utf8)
  (write-unreadable-import)
  (write-big)
  (write-corpus)
  (write-site)
  (write-mutated)
  (write-large)
  (write-deep)
  (write-flat))
