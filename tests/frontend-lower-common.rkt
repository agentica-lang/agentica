#lang racket

; The text form of lowering, printed from the Racket lowering (src/lower.rkt). compiler/lower.agc prints the
; same text; see lower_text.agc for the format. `--dump-ir` is not used: it keeps only the start line and
; column of a span, leaves out the sources, the JSON field types of the structs and the file of each span,
; and prints a constant with Racket's ~s, and step 6 needs all of those.

(require racket/runtime-path
         "../src/checker.rkt"
         "../src/diagnostic.rkt"
         "../src/lower.rkt"
         "../src/modules.rkt"
         "../src/source.rkt"
         (only-in "frontend-catalog-common.rkt" debug-type)
         (only-in "frontend-check-common.rkt" check-failure-line)
         (only-in "frontend-lexer-common.rkt" quote-text float-bits diagnostic-line)
         "frontend-modules-common.rkt")

(provide lower-text
         lower-inputs
         lower-golden
         write-lower-goldens
         (struct-out lower-input))

; name is the fixture, root its root file.
(struct lower-input (name root))

(define-runtime-path fixtures "fixtures/frontend/lower")

(define (span-numbers index span)
  (define start (source-span-start span))
  (define end (source-span-end span))
  (format "~a:~a:~a-~a:~a" index
          (source-position-line start) (source-position-column start)
          (source-position-line end) (source-position-column end)))

(define (imm-text value)
  (cond
    [(void? value) "void"]
    [(eq? value 'nil) "nil"]
    [(eq? value #t) "true"]
    [(eq? value #f) "false"]
    [(exact-integer? value) (format "int:~a" value)]
    [(flonum? value) (format "float:bits:~a" (float-bits value))]
    [(string? value) (quote-text value)]
    [else (error 'lower-text "unexpected constant ~s" value)]))

(define (arg-text op index value)
  (cond
    [(and (eq? op 'const) (= index 1)) (imm-text value)]
    [(and (memq op '(jump jump-if-false jump-if-true)) (= index (if (eq? op 'jump) 0 1))) (format "L~a" value)]
    [(and (memq op '(call tail-call closure)) (= index 1)) (format "fn~a" value)]
    [(and (memq op '(global global-set)) (= index 1)) (format "g~a" value)]
    [(and (memq op '(enum is-variant)) (= index 2)) (format "v~a" value)]
    [(and (memq op '(struct struct-with)) (= index 2)) (format "s~a" value)]
    [(and (eq? op 'struct-with) (= index 3)) (format "[~a]" (string-join (map number->string value) " "))]
    [(and (eq? op 'range) (= index 2)) (if (= value 1) "..." "..")]
    [(and (eq? op 'call-builtin) (= index 1)) (quote-text value)]
    [(and (memq op '(field payload list map call-builtin)) (= index 2)) (format "~a" value)]
    [(and (eq? op 'call-value) (= index 1)) (format "~a" value)]
    [else (format "r~a" value)]))

(define (instr-line source-index item)
  (define op (ir-instr-op item))
  (format "    ~a~a @ ~a" op
          (string-append* (for/list ([arg (in-list (ir-instr-args item))] [i (in-naturals)])
                            (string-append " " (arg-text op i arg))))
          (string-join (for/list ([span (in-list (ir-instr-spans item))])
                         (span-numbers (source-index (source-span-source span)) span))
                       " ")))

(define (struct-line index entry)
  (format "struct s~a ~a [~a]~a" index (quote-text (ir-struct-name entry))
          (string-join (map quote-text (ir-struct-fields entry)) ",")
          (if (ir-struct-types entry)
              (format " types=[~a]" (string-join (map debug-type (ir-struct-types entry)) ", "))
              "")))

(define (enum-lines entries)
  (let loop ([entries entries] [id 0] [out '()])
    (cond
      [(null? entries) (reverse out)]
      [else
       (define variants (ir-enum-variants (car entries)))
       (loop (cdr entries) (+ id (length variants))
             (cons (format "enum ~a~a" (quote-text (ir-enum-name (car entries)))
                           (string-append*
                            (for/list ([variant (in-list variants)] [k (in-naturals id)])
                              (format " v~a=~a/~a" k (quote-text (car variant)) (cdr variant)))))
                   out))])))

(define (function-lines source-index ir)
  (for/list ([function (in-list (ir-program-functions ir))] [index (in-naturals)])
    (string-join
     (cons (format "fn~a ~a params=~a captures=~a slots=~a~a @ ~a" index (quote-text (ir-function-name function))
                   (ir-function-params function) (ir-function-captures function) (ir-function-slots function)
                   (if (= index (ir-program-entry ir)) " entry" "")
                   (span-numbers (source-index (source-span-source (ir-function-span function))) (ir-function-span function)))
           (for/list ([item (in-list (ir-function-body function))])
             (if (ir-label? item)
                 (format "  L~a:" (ir-label-id item))
                 (instr-line source-index item))))
     "\n")))

; The program header, the sources (their names relative to the folder of the root file), the structs and
; enums, then the functions in table order.
(define (ir-lines folder ir)
  (define sources (ir-program-sources ir))
  (define (source-index text-source)
    (let loop ([rest sources] [at 0])
      (cond [(null? rest) (error 'lower-text "span of a source the program does not list")]
            [(eq? (car rest) text-source) at]
            [else (loop (cdr rest) (add1 at))])))
  (append
   (list (format "program ~a entry=~a globals=~a"
                 (span-numbers (source-index (source-span-source (ir-program-span ir))) (ir-program-span ir))
                 (ir-program-entry ir) (ir-program-globals ir)))
   (for/list ([text-source (in-list sources)] [index (in-naturals)])
     (format "source ~a ~a chars=~a" index (quote-text (display-path folder (source-name text-source)))
             (string-length (source-text text-source))))
   (for/list ([entry (in-list (ir-program-structs ir))] [index (in-naturals)]) (struct-line index entry))
   (enum-lines (ir-program-enums ir))
   (function-lines source-index ir)))

(define (lower-failure-line folder problem)
  (string-append (diagnostic-line problem)
                 " file=" (quote-text (display-path folder (file-name (diagnostic-span problem))))))

; The text form of lowering the file at root-path with the environment env: the IR, or the ERROR line of the
; first diagnostic of the linker, the checker or the lowering.
(define (lower-text root-path #:env [env default-env])
  (with-env env
    (lambda ()
      (define folder (root-folder root-path))
      (define linked (load-program root-path))
      (cond
        [(diagnostic? linked) (failure-line folder linked)]
        [else
         (define types (make-hasheq))
         (define checked (check linked #:types types))
         (cond
           [(diagnostic? checked) (check-failure-line folder checked)]
           [else
            (define ir (lower checked types))
            (if (diagnostic? ir)
                (lower-failure-line folder ir)
                (string-join (ir-lines folder ir) "\n"))])]))))

; A fixture is a NAME.agc file, or a folder NAME with a root.agc (for the programs that import files).
(define (lower-inputs)
  (for/list ([entry (in-list (sort (directory-list fixtures) path<?))]
             #:when (or (path-has-extension? entry #".agc") (directory-exists? (build-path fixtures entry))))
    (define name (path->string (path-replace-extension entry #"")))
    (lower-input name (if (directory-exists? (build-path fixtures entry))
                          (build-path fixtures entry "root.agc")
                          (build-path fixtures entry)))))

(define (lower-golden input)
  (build-path fixtures (string-append (lower-input-name input) ".ir")))

(define (write-lower-goldens)
  (define inputs (lower-inputs))
  (for ([input (in-list inputs)])
    (display-to-file (string-append (lower-text (lower-input-root input)) "\n")
                     (lower-golden input) #:exists 'truncate/replace))
  (define expected (map (lambda (input) (path->string (file-name-from-path (lower-golden input)))) inputs))
  (for ([file (in-list (directory-list fixtures))]
        #:when (and (path-has-extension? file #".ir")
                    (not (member (path->string file) expected))))
    (delete-file (build-path fixtures file)))
  (printf "frontend lower: ~a goldens\n" (length inputs)))

(module+ main
  (write-lower-goldens))
