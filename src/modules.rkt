#lang racket

(require racket/path "ast.rkt" "builtins.rkt" "checker.rkt"
         "diagnostic.rkt" "lexer.rkt" "parser.rkt" "source.rkt" "stdlib.rkt")

(provide link-program load-program)

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
      (define (bail code message span) (failed (diagnostic code message span)))
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
      (define locals (make-hash))
      (define exports (make-hash))
      (define order '())
      (define active '())
      (define (unwrap declaration)
        (if (export-decl? declaration) (export-decl-declaration declaration) declaration))
      (define (declaration-name declaration)
        (if (struct-decl? declaration) (struct-decl-name declaration) (function-decl-name declaration)))
      (define (visit key tree where)
        (when (member key active) (bail 'CHECK-IMPORT-CYCLE "import cycle" where))
        (unless (hash-has-key? trees key)
          (hash-set! trees key tree)
          (hash-set! prefixes key (if (equal? key root-key) "" (format "@~a::" (hash-count trees))))
          (set! order (cons key order))
          (set! active (cons key active))
          (define names (make-hash))
          (define public (make-hash))
          (define aliases (make-hash))
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
          (for ([declaration (in-list (program-declarations tree))] #:when (import-decl? declaration))
            (define alias (import-decl-alias declaration))
            (define path (import-decl-path declaration))
            (define span (node-span declaration))
            (when (or (hash-has-key? aliases alias) (hash-has-key? names alias)
                      (member alias reserved-type-names))
              (bail 'CHECK-REDEFINED-NAME "duplicate or reserved import alias" span))
            (unless (string-suffix? path ".agc")
              (bail 'CHECK-IMPORT-PATH "import paths must end in .agc" span))
            (define target
              (with-handlers ([exn:fail? (lambda (_) (bail 'CHECK-IMPORT-IO "cannot resolve import" span))])
                (resolve-import key path span)))
            (hash-set! aliases alias target)
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
               (visit target parsed span)]))
          (set! active (cdr active))))
      (visit root-key root (program-span root))
      (define (identity key name) (string-append (hash-ref prefixes key) name))
      (define (resolve key name kind span)
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
                (bail 'CHECK-IMPORT-NAME "unknown or private imported name" span))
              (unless (if (eq? kind 'type) (struct-decl? declaration) (function-decl? declaration))
                (bail 'CHECK-TYPE-MISMATCH "wrong kind of imported declaration" span))
              (identity target member)]
             ;; Unknown calls belong to the checker, including misspelled
             ;; builtin module functions. Keep their stable diagnostic code.
             [(eq? kind 'function) name]
             [else (bail 'CHECK-IMPORT-NAME "unknown module alias" span)])]
          [(and (eq? kind 'type) (member name reserved-type-names)) name]
          [(and (eq? kind 'function) (builtin-ref name)) name]
          [else (identity key name)]))
      (define (rewrite key node)
        (define (walk node) (rewrite key node))
        (define (walks nodes) (map walk nodes))
        (match node
          [(type-ref name args span) (type-ref (resolve key name 'type span) (walks args) span)]
          [(type-expression name span) (type-expression (resolve key name 'type span) span)]
          [(function-decl name params result body span)
           (function-decl (identity key name) (walks params) (walk result) (walks body) span)]
          [(struct-decl name fields span) (struct-decl (identity key name) (walks fields) span)]
          [(param name type span) (param name (walk type) span)]
          [(field-decl name type span) (field-decl name (walk type) span)]
          [(call name args span) (call (resolve key name 'function span) (walks args) span)]
          [(function-ref name span) (function-ref (resolve key name 'function span) span)]
          [(construct name args span) (construct (resolve key name 'type span) (walks args) span)]
          [(binding name type value span) (binding name (and type (walk type)) (walk value) span)]
          [(return-stmt value span) (return-stmt (and value (walk value)) span)]
          [(expr-stmt value span) (expr-stmt (walk value) span)]
          [(if-branch condition body span) (if-branch (walk condition) (walks body) span)]
          [(if-stmt branches otherwise span)
           (if-stmt (walks branches) (and otherwise (walks otherwise)) span)]
          [(while-stmt condition body span) (while-stmt (walk condition) (walks body) span)]
          [(for-stmt name iterable body span) (for-stmt name (walk iterable) (walks body) span)]
          [(invoke target args span) (invoke (walk target) (walks args) span)]
          [(named-arg name value span) (named-arg name (walk value) span)]
          [(list-lit elements span) (list-lit (walks elements) span)]
          [(map-lit entries span) (map-lit (walks entries) span)]
          [(map-entry key value span) (map-entry (walk key) (walk value) span)]
          [(field-access target name span) (field-access (walk target) name span)]
          [(index-access target index span) (index-access (walk target) (walk index) span)]
          [(try-expr operand span) (try-expr (walk operand) span)]
          [(unary op op-span operand span) (unary op op-span (walk operand) span)]
          [(binary op op-span left right span) (binary op op-span (walk left) (walk right) span)]
          [(or (literal _ _) (name-ref _ _)) node]
          [_ (bail 'CHECK-INTERNAL "unsupported module node" (node-span node))]))
      (program
       (append-map
        (lambda (key)
          (for/list ([wrapped (in-list (program-declarations (hash-ref trees key)))]
                     #:unless (import-decl? wrapped))
            (rewrite key (unwrap wrapped))))
        (reverse order))
       (program-span root)))))
