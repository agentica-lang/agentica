#lang racket

; The text form of a linked program, printed from the Racket linker (src/modules.rkt). compiler/link.agc
; prints the same text; see link_text.agc for the format.

(require racket/runtime-path
         "../src/ast.rkt"
         "../src/diagnostic.rkt"
         "../src/lexer.rkt"
         "../src/modules.rkt"
         "../src/parser.rkt"
         "../src/source.rkt"
         (only-in "frontend-lexer-common.rkt" quote-text span-text diagnostic-line)
         "frontend-parser-common.rkt")

(provide link-text
         module-sizes
         default-env
         env-arguments
         display-path
         module-inputs
         (struct-out module-input)
         module-golden
         write-module-goldens
         stdlib-folder)

; dir is the fixture folder, root its root file, env the environment variables of the pkg/ search.
(struct module-input (name dir root env))

(define-runtime-path root "..")
(define-runtime-path fixtures "fixtures/frontend/modules")
(define-runtime-path stdlib-folder "../stdlib")

; Hermetic: no AGENTICA_PATH, and a user data folder that does not exist.
(define default-env (hash "AGENTICA_PATH" "" "XDG_DATA_HOME" "/nonexistent-agentica-xdg"))

(define (env-arguments env)
  (append (list (string-append "--agentica-path=" (hash-ref env "AGENTICA_PATH"))
                (string-append "--xdg-data-home=" (hash-ref env "XDG_DATA_HOME")))
          (if (hash-has-key? env "HOME") (list (string-append "--home=" (hash-ref env "HOME"))) '())))

(define (with-env env thunk)
  (define copy (environment-variables-copy (current-environment-variables)))
  (for ([(name value) (in-hash env)])
    (environment-variables-set! copy (string->bytes/utf-8 name) (string->bytes/utf-8 value)))
  (parameterize ([current-environment-variables copy]) (thunk)))

; The folder of the root file as a string without a final "/" (except "/" itself), or #f when it does not
; exist; the paths of the text form are relative to it.
(define (root-folder root-path)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define text (path->string (path-only (normalize-path (path->complete-path root-path)))))
    (if (and (> (string-length text) 1) (string-suffix? text "/"))
        (substring text 0 (sub1 (string-length text)))
        text)))

(define (display-path folder name)
  (define prefix (and folder (if (string-suffix? folder "/") folder (string-append folder "/"))))
  (if (and prefix (string-prefix? name prefix))
      (substring name (string-length prefix))
      name))

(define (file-name span)
  (source-name (source-span-source span)))

(define (module-text name)
  (if (string-prefix? name "std/")
      (file->string (build-path stdlib-folder (substring name 4)))
      (file->string name)))

; A file parsed again by the test, to know the ids and the docs of its original nodes (the linker does not
; keep them): the ids by node, the docs by the offsets of a node's span, and the declarations without imports
; or exports, in the order the linker emits them.
(struct original (program ids docs declarations))

(define (parse-original name)
  (define tree (parse (lex (source name (module-text name)))))
  (when (diagnostic? tree) (error 'link-text "the linker accepted ~a, the parser does not" name))
  (original tree
            (number-tree tree 0)
            (for/hash ([(span text) (in-hash (program-docs tree))])
              (values (cons (source-position-offset (source-span-start span))
                            (source-position-offset (source-span-end span)))
                      text))
            (for/list ([wrapped (in-list (program-declarations tree))] #:unless (import-decl? wrapped))
              (if (export-decl? wrapped) (export-decl-declaration wrapped) wrapped))))

; The declarations of the program grouped by the file they come from, in order.
(define (group-by-file declarations)
  (for/fold ([groups '()] #:result (reverse groups)) ([declaration (in-list declarations)])
    (define name (file-name (node-span declaration)))
    (if (and (pair? groups) (equal? (car (car groups)) name))
        (cons (cons name (append (cdr (car groups)) (list declaration))) (cdr groups))
        (cons (list name declaration) groups))))

; The linker rewrites every node into a new one of the same shape, so a rewritten node takes the id and the
; doc of the node of the original tree at the same place.
(define (pair-nodes! ids docs rewritten old-root orig)
  (let walk ([new rewritten] [old old-root])
    (hash-set! ids new (hash-ref (original-ids orig) old))
    (hash-set! docs new (hash-ref (original-docs orig) (offsets (node-span old)) #f))
    (define new-children (node-children new))
    (define old-children (node-children old))
    (unless (= (length new-children) (length old-children))
      (error 'link-text "a rewritten node changed shape: ~s" new))
    (for-each walk new-children old-children)))

(define (offsets span)
  (cons (source-position-offset (source-span-start span)) (source-position-offset (source-span-end span))))

(define (module-lines! emit! root-folder name declarations orig)
  (define ids (make-hasheq))
  (define docs (make-hasheq))
  (unless (= (length declarations) (length (original-declarations orig)))
    (error 'link-text "~a: ~a declarations linked, ~a parsed" name (length declarations)
           (length (original-declarations orig))))
  (for ([new (in-list declarations)] [old (in-list (original-declarations orig))])
    (pair-nodes! ids docs new old orig))
  (emit! (string-append "  module " (quote-text (display-path root-folder name))))
  (for ([declaration (in-list declarations)])
    (emit-tree! emit! declaration "declaration" "    "
                (lambda (node) (hash-ref ids node))
                (lambda (node) (hash-ref docs node #f)))))

(define (linked-lines linked root-name folder)
  (define originals (make-hash))
  (define (original-of name) (hash-ref! originals name (lambda () (parse-original name))))
  (define root-original (original-of root-name))
  (define out '())
  (define (emit! line) (set! out (cons line out)))
  (emit! (format "program #~a ~a~a"
                 (hash-ref (original-ids root-original) (original-program root-original))
                 (span-text (program-span linked))
                 (if (program-module-doc linked)
                     (string-append " module-doc=" (quote-text (program-module-doc linked)))
                     "")))
  (parameterize ([current-update-universe
                  (for/list ([declaration (in-list (program-declarations linked))] #:when (struct-decl? declaration))
                    (struct-decl-name declaration))])
    (for ([group (in-list (group-by-file (program-declarations linked)))])
      (module-lines! emit! folder (car group) (cdr group) (original-of (car group)))))
  (reverse out))

(define (failure-line folder problem)
  (string-append (diagnostic-line problem)
                 " file=" (quote-text (display-path folder (file-name (diagnostic-span problem))))))

; The text form of linking the file at root-path with the environment env (a hash of the variables the pkg/
; search reads): the linked program, or the ERROR line of the first diagnostic.
(define (link-text root-path #:env [env default-env])
  (with-env env
    (lambda ()
      (define folder (root-folder root-path))
      (define linked (load-program root-path))
      (if (diagnostic? linked)
          (failure-line folder linked)
          (string-join (linked-lines linked (path->string (path->complete-path root-path)) folder) "\n")))))

; The number of nodes of each file, by the name of the file as the linker names it: what the first and
; next ids of `link.agc --ids` must add up to.
(define (module-sizes names)
  (for/list ([name (in-list names)])
    (define orig (parse-original name))
    (cons name (hash-count (original-ids orig)))))

(define (fixture-env dir)
  (define file (build-path dir "fixture.env"))
  (define absolute (path->string (simplify-path dir)))
  (if (file-exists? file)
      (for/fold ([env default-env]) ([line (in-list (file->lines file))] #:unless (string=? line ""))
        (match-define (list _ name value) (regexp-match #rx"^([^=]*)=(.*)$" line))
        (hash-set env name (string-replace value "@/" (string-append absolute "/"))))
      default-env))

; A fixture is a folder with a root.agc, the other files it imports, an optional fixture.env of NAME=VALUE
; lines for the pkg/ search (@/ stands for the folder of the fixture) and an optional fixture.links.
(define (module-inputs)
  (define scratch (make-temporary-directory "agentica-modules~a"))
  (plumber-add-flush! (current-plumber) (lambda (_) (when (directory-exists? scratch) (delete-directory/files scratch))))
  (for/list ([dir (in-list (sort (directory-list fixtures #:build? #t) path<?))]
             #:when (directory-exists? dir))
    (define name (path->string (file-name-from-path dir)))
    (define used (with-links dir (build-path scratch name)))
    (module-input name used (build-path used "root.agc") (fixture-env used))))

; Symbolic links are not kept in the repository (a checkout may drop or copy them): a fixture lists them in
; fixture.links as `LINK TARGET` lines, and a fixture that has the file is copied to the scratch folder with
; its links made there. Other fixtures are used where they are.
(define (with-links dir copy)
  (define listing (build-path dir "fixture.links"))
  (cond
    [(file-exists? listing)
     (copy-directory/files dir copy)
     (for ([line (in-list (file->lines listing))] #:unless (string=? line ""))
       (match-define (list link target) (string-split line " "))
       (make-parent-directory* (build-path copy link))
       (make-file-or-directory-link target (build-path copy link)))
     copy]
    [else dir]))

(define (module-golden input)
  (build-path fixtures (string-append (module-input-name input) ".linked")))

(define (write-module-goldens)
  (define inputs (module-inputs))
  (for ([input (in-list inputs)])
    (display-to-file (string-append (link-text (module-input-root input) #:env (module-input-env input)) "\n")
                     (module-golden input) #:exists 'truncate/replace))
  (define expected (map (lambda (input) (path->string (file-name-from-path (module-golden input)))) inputs))
  (for ([file (in-list (directory-list fixtures))]
        #:when (and (path-has-extension? file #".linked")
                    (not (member (path->string file) expected))))
    (delete-file (build-path fixtures file)))
  (printf "frontend modules: ~a goldens\n" (length inputs)))

(module+ main
  (write-module-goldens))
