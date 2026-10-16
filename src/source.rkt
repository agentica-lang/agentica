#lang racket

(require racket/path)

(provide (struct-out source)
         (struct-out source-position)
         (struct-out source-span))

;; Opaque so a printed tree shows #<source> instead of the whole file text.
(struct source (name text))
(struct source-position (offset line column) #:transparent)
(struct source-span (source start end) #:transparent)

;; The path stored for each source of a program in an .agcb (35.4, "Source
;; paths"), so the bytes do not depend on where the checkout lives. The project
;; root is the folder of the entry file, the same folder that anchors agc_libs/.
;; A file inside it is stored as its path from there, joined with "/" and with
;; no "./" ("main.agc", "lib/util.agc"). A file above the root keeps the ".."
;; parts ("../shared/x.agc"). The entry file is its own file name. A std/ module
;; keeps its std/NAME.agc key; a user file whose path starts with std/ is
;; "./std/NAME.agc". Only a file on another drive (Windows) stays
;; absolute. Imports are already canonical (modules.rkt), so the root is
;; canonicalized the same way (normalize-path resolves links) before comparing.
(provide stored-source-names stored-relative-name relative-source-name)

(define (stored-source-names root sources)
  (define root-name (source-name root))
  (define complete (path->complete-path root-name))
  (define root-file
    (with-handlers ([exn:fail? (lambda (_) (simplify-path complete #f))])
      (normalize-path complete)))
  (define-values (folder file _dir?) (split-path root-file))
  (for/list ([text-source (in-list sources)])
    (define name (source-name text-source))
    (cond
      [(eq? text-source root) (path->string file)]
      [(absolute-path? name) (stored-relative-name folder name)]
      [else name])))

;; The stored name of an imported file. A user file under a std/ folder of the
;; project would look like a standard module (and the VM puts --source-root
;; before every name but those), so it is written "./std/NAME.agc".
(define (stored-relative-name folder name)
  (define relative (relative-source-name folder name))
  (if (string-prefix? relative "std/") (string-append "./" relative) relative))

;; The path of `name` from `folder`, both absolute. "." and ".." parts are
;; folded first, so explode-path never yields 'up or 'same; any failure (a
;; malformed path) keeps the name, so no exception leaves a stage.
(define (relative-source-name folder name)
  (with-handlers ([exn:fail? (lambda (_) (if (path? name) (path->string name) name))])
    (define from (explode-path (simplify-path folder #f)))
    (define to (explode-path (simplify-path (if (path? name) name (string->path name)) #f)))
    (define (common-length a b)
      (if (and (pair? a) (pair? b) (equal? (car a) (car b)))
          (add1 (common-length (cdr a) (cdr b)))
          0))
    (define shared (common-length from to))
    (if (zero? shared)
        (if (path? name) (path->string name) name)
        (string-join (append (for/list ([_ (in-list (drop from shared))]) "..")
                             (map path-element->string (drop to shared)))
                     "/"))))

;; The --source-root option of agentica run: the folder of the entry file as a
;; user should type it, which the VM puts before the stored names it prints, so
;; a runtime trace names a file the way a compile-time diagnostic does. It is
;; relative to the working directory (built from the canonical folder, so the
;; ".." names of an imported file stay right through symbolic links), or
;; absolute when the entry was typed as an absolute path. "" when the entry is
;; in the working directory.
(provide source-root-option)

(define (source-root-option entry)
  (with-handlers ([exn:fail? (lambda (_) "")])
    (define-values (folder _file _dir?) (split-path (normalize-path (path->complete-path entry))))
    (define absolute (path->string (path->directory-path folder)))
    (define text
      (if (absolute-path? entry)
          absolute
          (relative-source-name (normalize-path (current-directory)) folder)))
    (if (and (> (string-length text) 1) (string-suffix? text "/"))
        (substring text 0 (sub1 (string-length text)))
        text)))
