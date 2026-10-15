#lang racket

; The text form of a check, printed from the Racket checker (src/checker.rkt). compiler/check.agc prints the
; same text; see check_text.agc for the format.

(require racket/runtime-path
         "../src/ast.rkt"
         "../src/checker.rkt"
         "../src/diagnostic.rkt"
         "../src/modules.rkt"
         "../src/source.rkt"
         (only-in "frontend-catalog-common.rkt" debug-type)
         (only-in "frontend-lexer-common.rkt" quote-text span-text diagnostic-line)
         "frontend-modules-common.rkt")

(provide check-text
         check-inputs
         check-golden
         write-check-goldens
         (struct-out check-input))

; name is the fixture, root its root file.
(struct check-input (name root))

(define-runtime-path fixtures "fixtures/frontend/check")
(define-runtime-path modules-fixtures "fixtures/frontend/modules")

; What a method call or a field access that names a builtin became. The checker keeps it in the node as a
; synthetic node whose receiver is a typed-target.
(define (resolved-note node)
  (define resolved
    (cond [(method-call? node) (method-call-resolved node)]
          [(field-access? node) (field-access-resolved node)]
          [else #f]))
  (define (receiver-type target) (debug-type (typed-target-type target)))
  (cond
    [(not resolved) ""]
    [(typed-target? resolved) (format " resolved=self(~a)" (receiver-type resolved))]
    [(interpolation? resolved) (format " resolved=text(~a)" (receiver-type (car (interpolation-parts resolved))))]
    [(inspection? resolved) (format " resolved=inspect(~a)" (receiver-type (inspection-target resolved)))]
    [(call? resolved)
     (format " resolved=call(~a, ~a)" (quote-text (call-name resolved)) (receiver-type (car (call-args resolved))))]
    [else (error 'check-text "unexpected resolution ~s" resolved)]))

(define (notes-of types)
  (lambda (node)
    (define type (hash-ref types node #f))
    (string-append (if type (format " type=~a" (debug-type type)) "") (resolved-note node))))

(define (note label text)
  (if (and text (not (string=? text ""))) (string-append label (quote-text text)) ""))

(define (check-failure-line folder problem)
  (define labels (diagnostic-labels problem))
  (string-append (diagnostic-line problem)
                 (note " expected=" (diagnostic-expected problem))
                 (note " actual=" (diagnostic-actual problem))
                 (note " callee=" (diagnostic-callee problem))
                 (note " signature=" (diagnostic-signature problem))
                 (if (null? labels)
                     ""
                     (format " labels=[~a]"
                             (string-join (for/list ([label (in-list labels)])
                                            (format "~a ~a" (span-text (car label)) (quote-text (cdr label))))
                                          ", ")))
                 " file=" (quote-text (display-path folder (file-name (diagnostic-span problem))))))

; The text form of checking the file at root-path with the environment env: the linked program with the type
; of each expression at the end of its line, the ERROR line of the linker, or that of the checker.
(define (check-text root-path #:env [env (hash "AGENTICA_PATH" "" "XDG_DATA_HOME" "/nonexistent-agentica-xdg")])
  (with-env env
    (lambda ()
      (define folder (root-folder root-path))
      (define linked (load-program root-path))
      (cond
        [(diagnostic? linked) (failure-line folder linked)]
        [else
         (define types (make-hasheq))
         (define checked (check linked #:types types))
         (if (diagnostic? checked)
             (check-failure-line folder checked)
             (string-join (linked-lines linked (path->string (path->complete-path root-path)) folder (notes-of types))
                          "\n"))]))))

; A fixture is a NAME.agc file, or a folder NAME with a root.agc (for the programs that import files).
(define (check-inputs)
  (for/list ([entry (in-list (sort (directory-list fixtures) path<?))]
             #:when (or (path-has-extension? entry #".agc") (directory-exists? (build-path fixtures entry))))
    (define name (path->string (path-replace-extension entry #"")))
    (check-input name (if (directory-exists? (build-path fixtures entry))
                          (build-path fixtures entry "root.agc")
                          (build-path fixtures entry)))))

(define (check-golden input)
  (build-path fixtures (string-append (check-input-name input) ".checked")))

(define (write-check-goldens)
  (define inputs (check-inputs))
  (for ([input (in-list inputs)])
    (display-to-file (string-append (check-text (check-input-root input)) "\n")
                     (check-golden input) #:exists 'truncate/replace))
  (define expected (map (lambda (input) (path->string (file-name-from-path (check-golden input)))) inputs))
  (for ([file (in-list (directory-list fixtures))]
        #:when (and (path-has-extension? file #".checked")
                    (not (member (path->string file) expected))))
    (delete-file (build-path fixtures file)))
  (printf "frontend check: ~a goldens\n" (length inputs)))

(module+ main
  (write-check-goldens))
