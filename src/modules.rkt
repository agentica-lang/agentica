#lang racket

(require racket/path "ast.rkt" "builtins.rkt" "builtin-types.rkt" "checker.rkt"
         "diagnostic.rkt" "lexer.rkt" "parser.rkt" "source.rkt" "stdlib.rkt")

(provide link-program load-program)

;; Style rule, no meaning for evaluation: imports, then structs and enums, then
;; exported functions, then private functions. Returns the diagnostic for the
;; first declaration that comes after a later group, or #f.
(define (declaration-order-error declarations)
  (define (rank wrapped)
    (cond
      [(import-decl? wrapped) 0]
      [(or (struct-decl? wrapped) (enum-decl? wrapped)) 1]
      [(and (export-decl? wrapped)
            (let ([inner (export-decl-declaration wrapped)])
              (or (struct-decl? inner) (enum-decl? inner))))
       1]
      [(export-decl? wrapped) 2]
      [else 3]))
  (let loop ([remaining declarations] [highest 0])
    (cond
      [(null? remaining) #f]
      [(< (rank (car remaining)) highest)
       (define wrapped (car remaining))
       (diagnostic 'CHECK-DECL-ORDER
                   "declaration is out of order"
                   (node-span wrapped)
                   #:help (case (rank wrapped)
                            [(0) "imports come first, before any struct, enum or function"]
                            [(1) "structs and enums come before functions"]
                            [else "exported functions come before private functions"]))]
      [else (loop (cdr remaining) (max highest (rank (car remaining))))])))

(define (file-span path)
  (source-span (source (path->string (path->complete-path path)) "")
               (source-position 0 1 1) (source-position 0 1 1)))

(define (load-program path)
  (with-handlers ([exn:fail? (lambda (failure)
                             (diagnostic 'CHECK-IMPORT-IO (exn-message failure) (file-span path)))])
    (define tokens (lex (source (path->string (path->complete-path path)) (file->string path))))
    (define parsed (if (diagnostic? tokens) tokens (parse tokens)))
    (if (diagnostic? parsed) parsed (link-program parsed path))))

;; Linking gives every dependency its own identities, but keeps root names for
;; CLI/BDD entrypoints. No evaluation occurs here; spans stay in original files.
(define (link-program root root-path)
  (with-handlers ([exn:fail? (lambda (failure)
                             (diagnostic 'CHECK-IMPORT-IO (exn-message failure) (program-span root)))])
    (let/ec failed
      (define (bail code message span #:help [help #f]) (failed (diagnostic code message span #:help help)))
      (define (canonical path) (normalize-path (path->complete-path path)))
      (define root-key (canonical root-path))
      ;; pkg/ roots are anchored to the entrypoint, never the process cwd.
      (define (library-roots span)
        (define windows? (eq? (system-type 'os) 'windows))
        (define configured
          (filter (lambda (entry) (not (string=? entry "")))
                  (string-split (or (getenv "AGENTICA_PATH") "")
                                (if windows? ";" ":") #:trim? #f)))
        (for ([entry (in-list configured)])
          (unless (absolute-path? entry)
            (bail 'CHECK-IMPORT-PATH "AGENTICA_PATH roots must be absolute" span)))
        (define home (find-system-path 'home-dir))
        (define data (getenv (if windows? "LOCALAPPDATA" "XDG_DATA_HOME")))
        (define user-root
          (cond
            [(and data (absolute-path? data)) (build-path data "agentica" "lib")]
            [windows? (build-path home "AppData" "Local" "agentica" "lib")]
            [else (build-path home ".local" "share" "agentica" "lib")]))
        (append (list (build-path (path-only root-key) "agc_libs")) configured
                (list user-root)
                (if windows? '()
                    (list (string->path "/usr/local/share/agentica/lib")
                          (string->path "/usr/share/agentica/lib")))))
      (define (validate-library-path path span)
        (define parts (string-split path "/" #:trim? #f))
        (when (or (regexp-match? #rx"\\\\" path)
                  (for/or ([part (in-list parts)])
                    (or (member part '("" "." ".."))
                        (regexp-match? #rx":" part))))
          (bail 'CHECK-IMPORT-PATH "invalid library path" span)))
      (define (module-file path line span)
        (define (last-part text) (car (regexp-match #rx"[^/]*$" text)))
        (define (module-name? text)
          (define name (last-part text))
          (not (or (string=? name "") (regexp-match? #rx"[.]" name))))
        (define stem (and (string-suffix? path ".agc")
                          (substring path 0 (- (string-length path) 4))))
        (define guess (regexp-replace #rx"[.][^./]*$" path ""))
        (cond
          [(module-name? path) (string-append path ".agc")]
          [(and stem (module-name? stem))
           (bail 'CHECK-IMPORT-PATH "import paths name a module without the .agc extension" span
                 #:help (format "write ~a" (line stem)))]
          [(member (last-part path) '("" "." ".."))
           (bail 'CHECK-IMPORT-PATH "import paths name a module file" span
                 #:help (format "write ~a to load models.agc" (line "models")))]
          [(module-name? guess)
           (bail 'CHECK-IMPORT-PATH "import paths name a module without an extension" span
                 #:help (format "write ~a to load ~a.agc" (line guess) guess))]
          [else
           (bail 'CHECK-IMPORT-PATH "a module file name has no dot apart from .agc" span
                 #:help "rename the file so its name has no dot apart from .agc")]))
      (define (resolve-import key path span)
        (cond
          [(string-prefix? path "std/")
           (validate-library-path path span)
           (unless (hash-has-key? stdlib-sources path)
             (bail 'CHECK-IMPORT-IO "unknown standard library module" span))
           path]
          [(string-prefix? path "pkg/")
           (validate-library-path path span)
           (or (for/or ([root (in-list (library-roots span))])
                 (define candidate (build-path root (substring path 4)))
                 (and (file-exists? candidate)
                      (let* ([base (canonical root)]
                             [target (canonical candidate)]
                             [base-parts (explode-path base)]
                             [target-parts (explode-path target)])
                        ;; Resolve links before checking containment.
                        (unless (and (>= (length target-parts) (length base-parts))
                                     (equal? base-parts (take target-parts (length base-parts))))
                          (bail 'CHECK-IMPORT-PATH "library path escapes its root" span))
                        target)))
               (bail 'CHECK-IMPORT-IO "cannot find library module" span))]
          [(string? key)
           ;; Relative dependencies of an embedded module stay in std/.
           (define parent (regexp-replace #rx"[^/]+$" key ""))
           (resolve-import key (string-append parent path) span)]
          [else (canonical (build-path (path-only key) path))]))
      (define (module-source key)
        (if (string? key) (hash-ref stdlib-sources key) (file->string key)))
      (define (module-name key)
        (if (string? key) key (path->string key)))
      (define trees (make-hash))
      (define prefixes (make-hash))
      (define imports (make-hash))
      (define named-imports (make-hash))
      (define locals (make-hash))
      (define exports (make-hash))
      (define order '())
      (define active '())
      (define (unwrap declaration)
        (if (export-decl? declaration) (export-decl-declaration declaration) declaration))
      (define (declaration-name declaration)
        (cond
          [(struct-decl? declaration) (struct-decl-name declaration)]
          [(enum-decl? declaration) (enum-decl-name declaration)]
          [else (function-decl-name declaration)]))
      ;; Only exports are candidates, so a private name is never suggested.
      (define (unknown-name-help target member)
        (cond
          [(and (equal? target "std/http.agc")
                (memv (string->symbol member) '(respond begin write write_bytes finish)))
           "a handler returns its whole response: return ok(HttpResponse(status: 200, headers: [], body: text))"]
          [(and (equal? target "std/logger.agc") (equal? member "error"))
           "the function for the error level is Logger.err; error is a reserved name"]
          [else (did-you-mean member (hash-keys (hash-ref exports target)))]))
      ;; The import line a help text shows for a path (written as a string): the alias form, or the name list.
      (define (import-line written alias entries)
        (if alias
            (format "import ~a from ~s" alias written)
            (format "import {~a} from ~s"
                    (string-join (for/list ([entry (in-list entries)])
                                   (if (equal? (import-name-name entry) (import-name-local entry))
                                       (import-name-name entry)
                                       (format "~a as ~a" (import-name-name entry) (import-name-local entry))))
                                 ", ")
                    written)))
      ;; A struct or an enum is renamed to a type name (a capital first letter), a function to a
      ;; lowercase one; the lexer tells the two apart by that letter.
      (define (type-name? text) (char<=? #\A (string-ref text 0) #\Z))
      (define (rename-help declaration)
        (cond
          [(struct-decl? declaration) "a struct is renamed to another type name, which starts with a capital letter"]
          [(enum-decl? declaration) "an enum is renamed to another type name, which starts with a capital letter"]
          [else "a function is renamed to another lowercase name"]))
      ;; One entry of an import list: the name must be an export, the new name must keep the case
      ;; rule of its kind, and the local name joins the file's names like a declaration. A name
      ;; imported twice, or clashing with anything else, is CHECK-REDEFINED-NAME at the local name.
      (define (bind-imported-name! target entry names aliases named)
        (define original (import-name-name entry))
        (define local (import-name-local entry))
        (define declaration (hash-ref (hash-ref exports target) original #f))
        (unless declaration
          (bail 'CHECK-IMPORT-NAME "unknown or private imported name" (import-name-span entry)
                #:help (unknown-name-help target original)))
        (unless (eq? (type-name? local) (not (function-decl? declaration)))
          (bail 'CHECK-IMPORT-RENAME "the new name does not follow the case rule of the imported name"
                (import-name-local-span entry) #:help (rename-help declaration)))
        (when (or (hash-has-key? names local) (hash-has-key? aliases local) (hash-has-key? named local)
                  (builtin-ref local) (member local reserved-type-names))
          (bail 'CHECK-REDEFINED-NAME "duplicate or reserved imported name" (import-name-local-span entry)))
        (hash-set! named local (cons target original)))
      (define (visit key tree where)
        (when (member key active) (bail 'CHECK-IMPORT-CYCLE "import cycle" where))
        (unless (hash-has-key? trees key)
          (define misplaced (declaration-order-error (program-declarations tree)))
          (when misplaced (failed misplaced))
          (hash-set! trees key tree)
          (hash-set! prefixes key (if (equal? key root-key) "" (format "@~a::" (hash-count trees))))
          (set! order (cons key order))
          (set! active (cons key active))
          (define names (make-hash))
          (define public (make-hash))
          (define aliases (make-hash))
          (define named (make-hash))
          (for ([wrapped (in-list (program-declarations tree))])
            (define declaration (unwrap wrapped))
            (unless (import-decl? declaration)
              (define name (declaration-name declaration))
              (when (or (hash-has-key? names name) (builtin-ref name)
                        (member name reserved-type-names))
                (bail 'CHECK-REDEFINED-NAME "duplicate or reserved declaration" (node-span wrapped)))
              (hash-set! names name declaration)
              (when (export-decl? wrapped) (hash-set! public name declaration))))
          (hash-set! locals key names)
          (hash-set! exports key public)
          (hash-set! imports key aliases)
          (hash-set! named-imports key named)
          (for ([declaration (in-list (program-declarations tree))] #:when (import-decl? declaration))
            (define alias (import-decl-alias declaration))
            (define entries (import-decl-names declaration))
            (define path (import-decl-path declaration))
            (define span (node-span declaration))
            (when (and alias
                       (or (hash-has-key? aliases alias) (hash-has-key? names alias)
                           (hash-has-key? named alias) (member alias reserved-type-names)))
              (bail 'CHECK-REDEFINED-NAME "duplicate or reserved import alias" span))
            (define file (module-file path (lambda (written) (import-line written alias entries)) span))
            (define target
              (with-handlers ([exn:fail? (lambda (_) (bail 'CHECK-IMPORT-IO "cannot resolve import" span))])
                (resolve-import key file span)))
            (when alias (hash-set! aliases alias target))
            (cond
              [(member target active) (bail 'CHECK-IMPORT-CYCLE "import cycle" span)]
              [(hash-has-key? trees target) (void)]
              [else
               (define tokens
                 (with-handlers ([exn:fail? (lambda (_) (bail 'CHECK-IMPORT-IO "cannot read import" span))])
                   (lex (source (module-name target) (module-source target)))))
               (when (diagnostic? tokens) (failed tokens))
               (define parsed (parse tokens))
               (when (diagnostic? parsed) (failed parsed))
               (visit target parsed span)])
            ;; The names are checked once the module is loaded, because they need its exports.
            (for ([entry (in-list entries)])
              (bind-imported-name! target entry names aliases named)))
          (set! active (cdr active))))
      (visit root-key root (program-span root))
      (define (identity key name) (string-append (hash-ref prefixes key) name))
      ;; The linked names of every struct a user module declares. A struct outside this table is a
      ;; builtin record, which every module may build.
      (define user-structs
        (for*/hash ([(key names) (in-hash locals)]
                    [(name declaration) (in-hash names)]
                    #:when (struct-decl? declaration))
          (values (identity key name) #t)))
      ;; A struct update builds a value, so it follows the rules of construction: a module may build
      ;; its own structs and the exported structs of the modules it imports, nothing else. The
      ;; checker asks this predicate once it knows the receiver's struct.
      (define constructible-cache (make-hash))
      (define (constructible key)
        (hash-ref! constructible-cache key
                   (lambda ()
                     (define allowed
                       (append
                        (for/list ([(name declaration) (in-hash (hash-ref locals key))]
                                   #:when (struct-decl? declaration))
                          (identity key name))
                        ;; A module imported by name counts as imported, with all its exported structs:
                        ;; an alias import of the same module would allow them too.
                        (for*/list ([target (in-list (append (hash-values (hash-ref imports key))
                                                             (map car (hash-values (hash-ref named-imports key)))))]
                                    [(name declaration) (in-hash (hash-ref exports target))]
                                    #:when (struct-decl? declaration))
                          (identity target name))))
                     (lambda (name) (or (not (hash-ref user-structs name #f)) (and (member name allowed) #t))))))
      (define (right-kind? declaration kind)
        (case kind
          [(type) (or (struct-decl? declaration) (enum-decl? declaration))]
          [(enum) (enum-decl? declaration)]
          [else (function-decl? declaration)]))
      ;; The module and original name behind a name imported by name into this file, or #f.
      (define (named-entry key name) (hash-ref (hash-ref named-imports key) name #f))
      (define (named-enum? key name)
        (define entry (named-entry key name))
        (and entry (enum-decl? (hash-ref (hash-ref exports (car entry)) (cdr entry)))))
      (define (resolve key name kind span #:variant-hint? [variant-hint? #f])
        (define parts (string-split name "."))
        (cond
          [(= (length parts) 2)
           (define alias (car parts))
           (define member (cadr parts))
           (define target (hash-ref (hash-ref imports key) alias #f))
           (cond
             [target
              (define declaration (hash-ref (hash-ref exports target) member #f))
              (unless declaration
                (bail 'CHECK-IMPORT-NAME "unknown or private imported name" span
                      #:help (unknown-name-help target member)))
              (unless (right-kind? declaration kind)
                (bail 'CHECK-TYPE-MISMATCH "wrong kind of imported declaration" span))
              (identity target member)]
             [(and (std-only-name? name) (not (string? key)))
              (bail 'CHECK-UNKNOWN-NAME (format "unknown function \"~a\"" name) span
                    #:help (let ([import (hash-ref std-only-imports alias)])
                             (format "~a is internal to ~a; use import ~a from \"~a\""
                                     alias (car import) (cdr import) (car import))))]
             ;; Unknown calls belong to the checker, including misspelled
             ;; builtin module functions. Keep their stable diagnostic code.
             [(eq? kind 'function) name]
             [else (bail 'CHECK-IMPORT-NAME "unknown module alias" span
                         #:help (cond
                                  [(equal? alias "BDD") "import BDD from \"std/bdd\""]
                                  [(equal? alias "HTTP") "import HTTP from \"std/http\""]
                                  [(equal? alias "Result")
                                   "write Result.Ok(value) or ok(value), Result.Err(\"message\") or error(\"message\")"]
                                  [variant-hint?
                                   (format "\"~a\" is neither an import alias nor an enum of this file; import a module with import ~a from \"path\", or declare enum ~a" alias alias alias)]
                                  [else (format "import a module with import ~a from \"path\"" alias)]))])]
          [(named-entry key name)
           => (lambda (entry)
                (unless (right-kind? (hash-ref (hash-ref exports (car entry)) (cdr entry)) kind)
                  (bail 'CHECK-TYPE-MISMATCH "wrong kind of imported declaration" span))
                (identity (car entry) (cdr entry)))]
          [(and (eq? kind 'type) (member name reserved-type-names)) name]
          [(and (eq? kind 'enum) (or (string=? name "Result") (hash-has-key? builtin-enums name))) name]
          [(and (eq? kind 'function) (builtin-ref name)) name]
          [else (identity key name)]))
      (define (rewrite key node)
        (define (walk node) (rewrite key node))
        (define (walks nodes) (map walk nodes))
        (match node
          [(type-ref name args span) (type-ref (resolve key name 'type span) (walks args) span)]
          [(type-expression name span)
           (define parts (string-split name "."))
           (cond
             [(and (= (length parts) 2)
                   (enum-decl? (hash-ref (hash-ref locals key) (car parts) #f)))
              (enum-constructor (identity key (car parts)) (cadr parts) '() span)]
             [(and (= (length parts) 2) (named-enum? key (car parts)))
              (enum-constructor (resolve key (car parts) 'enum span) (cadr parts) '() span)]
             [(and (= (length parts) 2) (hash-has-key? builtin-enums (car parts)))
              (enum-constructor (car parts) (cadr parts) '() span)]
             [else (type-expression (resolve key name 'type span #:variant-hint? #t) span)])]
          [(function-decl name params result body span)
           (function-decl (identity key name) (walks params) (walk result) (walks body) span)]
          [(struct-decl name fields span) (struct-decl (identity key name) (walks fields) span)]
          [(enum-decl name parameters variants span)
           (define (rewrite-enum-type node)
             (match node
               [(type-ref type-name args type-span)
                (type-ref (if (and (member type-name parameters) (null? args))
                              type-name
                              (resolve key type-name 'type type-span))
                          (map rewrite-enum-type args) type-span)]
               [_ (walk node)]))
           (enum-decl (identity key name) parameters
                      (for/list ([variant (in-list variants)])
                        (enum-variant (enum-variant-name variant)
                                      (map rewrite-enum-type (enum-variant-payload-types variant))
                                      (enum-variant-span variant)))
                      span)]
          [(enum-variant name payload-types span)
           (enum-variant name (walks payload-types) span)]
          [(variant-pattern enum-name variant-name bindings span)
           (variant-pattern (resolve key enum-name 'enum span) variant-name bindings span)]
          [(enum-constructor enum-name variant-name args span)
           (enum-constructor (resolve key enum-name 'enum span) variant-name (walks args) span)]
          [(param name type span) (param name (walk type) span)]
          [(field-decl name type span) (field-decl name (walk type) span)]
          [(call name args span piped)
           (call (resolve key name 'function span) (walks args) span piped)]
          [(function-ref name span) (function-ref (resolve key name 'function span) span)]
          [(construct name args span)
           (define parts (string-split name "."))
           (define alias-imports (hash-ref imports key))
           (cond
             [(and (= (length parts) 2)
                   (enum-decl? (hash-ref (hash-ref locals key) (car parts) #f)))
              (enum-constructor (identity key (car parts)) (cadr parts) (walks args) span)]
             [(and (= (length parts) 2) (named-enum? key (car parts)))
              (enum-constructor (resolve key (car parts) 'enum span) (cadr parts) (walks args) span)]
             [(and (= (length parts) 2) (hash-has-key? builtin-enums (car parts)))
              (enum-constructor (car parts) (cadr parts) (walks args) span)]
             [(and (= (length parts) 3)
                   (hash-has-key? alias-imports (car parts))
                   (enum-decl? (hash-ref (hash-ref exports (hash-ref alias-imports (car parts)))
                                         (cadr parts) #f)))
              (enum-constructor (resolve key (string-append (car parts) "." (cadr parts)) 'enum span)
                                (caddr parts) (walks args) span)]
             [else (construct (resolve key name 'type span) (walks args) span)])]
          [(binding name type value span) (binding name (and type (walk type)) (walk value) span)]
          [(return-stmt value span) (return-stmt (and value (walk value)) span)]
          [(expr-stmt value span) (expr-stmt (walk value) span)]
          [(if-branch condition body span) (if-branch (walk condition) (walks body) span)]
          [(if-stmt branches otherwise span)
           (if-stmt (walks branches) (and otherwise (walks otherwise)) span)]
          [(case-stmt value arms span) (case-stmt (walk value) (walks arms) span)]
          [(case-arm pattern body span) (case-arm (walk pattern) (walks body) span)]
          [(literal-pattern _ _) node]
          [(wildcard-pattern _) node]
          [(while-stmt condition body span) (while-stmt (walk condition) (walks body) span)]
          [(for-stmt name iterable body span) (for-stmt name (walk iterable) (walks body) span)]
          [(invoke target args span) (invoke (walk target) (walks args) span)]
          [(named-arg name value span) (named-arg name (walk value) span)]
          [(struct-update target args span _)
           (define update (struct-update (walk target) (walks args) span))
           (set-struct-update-visible! update (constructible key))
           update]
          [(list-lit elements span) (list-lit (walks elements) span)]
          [(map-lit entries span) (map-lit (walks entries) span)]
          [(map-entry key value span) (map-entry (walk key) (walk value) span)]
          [(field-access target name span _) (field-access (walk target) name span)]
          [(method-call target name args span _) (method-call (walk target) name (walks args) span)]
          [(interpolation parts span)
           (interpolation (for/list ([part (in-list parts)]) (if (string? part) part (walk part))) span)]
          [(index-access target index span) (index-access (walk target) (walk index) span)]
          [(block-lit params body span) (block-lit (walks params) (walks body) span)]
          [(block-param name type span) (block-param name (and type (walk type)) span)]
          [(try-expr operand span) (try-expr (walk operand) span)]
          [(unary op op-span operand span) (unary op op-span (walk operand) span)]
          [(binary op op-span left right span) (binary op op-span (walk left) (walk right) span)]
          [(or (literal _ _) (name-ref _ _) (loop-control _ _)) node]
          [_ (bail 'CHECK-INTERNAL "unsupported module node" (node-span node))]))
      (program
       (append-map
        (lambda (key)
          (for/list ([wrapped (in-list (program-declarations (hash-ref trees key)))]
                     #:unless (import-decl? wrapped))
            (rewrite key (unwrap wrapped))))
        (reverse order))
       (program-span root)
       (program-docs root)
       (program-module-doc root)))))
