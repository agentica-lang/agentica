#lang racket

; What the Racket writers of the frozen comparisons share (tests/frontend-<stage>-freeze.rkt, run by
; `make frontend-freeze`). They run a Racket stage over the inputs of tests/fixtures/frontend/frozen/ once and write
; what it printed, so the Python tests can compare the Agentica stage with it after the Racket stages are gone
; (docs/future/35-self-hosting.md, 35.10, phase 3).
;
; The inputs are of three kinds:
;   - the snapshot of the corpus (examples/, stdlib/, tests/fixtures/ and compiler/ at the time of the freeze), in
;     frozen/corpus/*.json as a map from path to text. It is not refreshed when those folders change: the freeze is
;     a fixed set of inputs, not a second copy that follows the repository;
;   - generated inputs that came from a seeded Racket generator (frozen/<stage>/*.json), kept because Python cannot
;     draw the same numbers;
;   - generated inputs that are a formula (a nesting shape, a long chain), which the Python tests rebuild. Their
;     manifests record the SHA-256 of each input, so a rebuild that differs from the Racket one fails.
;
; A manifest (frozen/<stage>/<set>.sha256) has one line for each input: the SHA-256 of what the Racket stage printed,
; its size in bytes, the SHA-256 of the input and the name of the input.

(require racket/runtime-path
         json
         file/sha1)

(provide frozen-folder
         sha256-hex
         write-frozen
         read-frozen-json
         write-frozen-json
         materialize-corpus
         corpus-paths
         with-corpus
         write-manifest
         manifest-line
         text-bytes
         repo-root)

(define-runtime-path repo-root "..")
(define-runtime-path frozen-folder "fixtures/frontend/frozen")

(define (text-bytes text) (if (bytes? text) text (string->bytes/utf-8 text)))

(define (sha256-hex data) (bytes->hex-string (sha256-bytes (text-bytes data))))

; Writes the file below the frozen folder, with exactly this text.
(define (write-frozen relative text)
  (define path (build-path frozen-folder relative))
  (make-parent-directory* path)
  (call-with-output-file path #:exists 'truncate/replace (lambda (out) (void (write-bytes (text-bytes text) out)))))

; The JSON text of a value with the keys of every object sorted, so a rewrite changes only what changed.
(define (compact value)
  (cond
    [(hash? value)
     (string-append "{"
                    (string-join (for/list ([key (in-list (sort (hash-keys value) symbol<?))])
                                   (string-append (jsexpr->string (symbol->string key)) ":" (compact (hash-ref value key))))
                                 ",")
                    "}")]
    [(list? value) (string-append "[" (string-join (map compact value) ",") "]")]
    [else (jsexpr->string value)]))

; One entry for each line at the top level (an object or an array), compact below it.
(define (json-text value)
  (cond
    [(hash? value)
     (string-append "{\n"
                    (string-join (for/list ([key (in-list (sort (hash-keys value) symbol<?))])
                                   (string-append " " (jsexpr->string (symbol->string key)) ": " (compact (hash-ref value key))))
                                 ",\n")
                    "\n}\n")]
    [(list? value)
     (string-append "[\n" (string-join (for/list ([item (in-list value)]) (string-append " " (compact item))) ",\n") "\n]\n")]
    [else (string-append (compact value) "\n")]))

(define (write-frozen-json relative value) (write-frozen relative (json-text value)))

(define (read-frozen-json relative)
  (call-with-input-file (build-path frozen-folder relative) read-json))

; The paths and texts of the snapshot, as a hash from path to text.
(define corpus-names '("examples" "stdlib" "fixtures" "compiler"))

(define (corpus-paths)
  (for/fold ([all (hash)]) ([name (in-list corpus-names)])
    (for/fold ([all all]) ([(path text) (in-hash (read-frozen-json (format "corpus/~a.json" name)))])
      (hash-set all (symbol->string path) text))))

; Writes the snapshot below dir, each file at its path.
(define (materialize-corpus dir)
  (for ([(path text) (in-hash (corpus-paths))])
    (define target (build-path dir path))
    (make-parent-directory* target)
    (display-to-file text target #:exists 'truncate/replace)))

; Calls (proc dir) with the snapshot written under a temporary folder, which is deleted afterwards.
(define (with-corpus proc)
  (define dir (make-temporary-directory "agentica-freeze~a"))
  (dynamic-wind
    void
    (lambda () (materialize-corpus dir) (proc dir))
    (lambda () (delete-directory/files dir))))

(define (manifest-line output input key)
  (format "~a ~a ~a ~a" (sha256-hex output) (bytes-length (text-bytes output)) (sha256-hex input) key))

; entries: (list key output input) in the order the Python test lists them.
(define (write-manifest relative entries)
  (write-frozen relative
                (string-append* (for/list ([entry (in-list entries)])
                                  (string-append (manifest-line (second entry) (third entry) (first entry)) "\n"))))
  (printf "~a: ~a entries\n" relative (length entries)))

(provide tree-listing
         write-tree
         call-with-temporary-folder)

; The text a hash of a whole input stands for: the path of each file and the SHA-256 of its content, one line each, in
; path order. files is a list of (path . text-or-bytes), the paths relative to the root of the input. The Python tests
; build the same text (tests/frontend_support.py, tree_listing).
(define (tree-listing files)
  (string-append*
   (for/list ([file (in-list (sort files string<? #:key car))])
     (format "~a ~a\n" (car file) (sha256-hex (cdr file))))))

; Writes the files (path . text-or-bytes) below dir.
(define (write-tree dir files)
  (for ([file (in-list files)])
    (define target (build-path dir (car file)))
    (make-parent-directory* target)
    (call-with-output-file target #:exists 'truncate/replace (lambda (out) (void (write-bytes (text-bytes (cdr file)) out))))))

; Calls (proc dir) with a new temporary folder, which is deleted afterwards.
(define (call-with-temporary-folder proc)
  (define dir (make-temporary-directory "agentica-freeze~a"))
  (dynamic-wind void (lambda () (proc (simplify-path dir))) (lambda () (delete-directory/files dir))))

(provide program-entries
         numbered
         direct-files
         std-wrappers)

; Writes the programs (key . text) below dir as <folder>/<key>.agc and gives their manifest entries, with the output of
; (output-of path) for each.
(define (program-entries dir folder programs output-of)
  (for/list ([entry (in-list programs)])
    (define path (format "~a/~a.agc" folder (car entry)))
    (write-tree dir (list (cons path (cdr entry))))
    (list (car entry) (output-of (path->string (build-path dir path))) (cdr entry))))

(define (numbered prefix texts)
  (for/list ([text (in-list texts)] [n (in-naturals)]) (cons (format "~a~a" prefix n) text)))

; The files of a folder and not of its subfolders: the keys of the corpus (a hash from path to text), sorted.
(define (direct-files files folder)
  (sort (for/list ([key (in-hash-keys files)]
                   #:when (and (string-prefix? key (string-append folder "/"))
                               (not (string-contains? (substring key (add1 (string-length folder))) "/"))))
          key)
        string<?))

; One program for each std/ module that imports it, so that the module is taken through the linker like a user would.
(define (std-wrappers files)
  (for/list ([key (in-list (sort (hash-keys files) string<?))] #:when (string-prefix? key "stdlib/"))
    (define name (string-trim (substring key (string-length "stdlib/")) ".agc" #:left? #f))
    (cons (string-append "std-" (string-replace name "/" "_"))
          (format "import Module from \"std/~a\"\n\ndef main() -> Void\nend\n" name))))
