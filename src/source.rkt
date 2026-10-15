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
;; keeps its std/NAME.agc key. Only a file on another drive (Windows) stays
;; absolute. Imports are already canonical (modules.rkt), so the root is
;; canonicalized the same way (normalize-path resolves links) before comparing.
(provide stored-source-names relative-source-name)

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
      [(absolute-path? name) (relative-source-name folder name)]
      [else name])))

(define (relative-source-name folder name)
  (define from (explode-path folder))
  (define to (explode-path (string->path name)))
  (define (common-length a b)
    (if (and (pair? a) (pair? b) (equal? (car a) (car b)))
        (add1 (common-length (cdr a) (cdr b)))
        0))
  (define shared (common-length from to))
  (if (zero? shared)
      name
      (string-join (append (for/list ([_ (in-list (drop from shared))]) "..")
                           (map path-element->string (drop to shared)))
                   "/")))
