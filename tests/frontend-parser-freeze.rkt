#lang racket

; Freezes the live comparisons of tests/frontend-parser-test.rkt: the Racket parser over the corpus, the 300 generated
; inputs, the nesting limit, the large files, the numbering of node ids and a file with invalid UTF-8.
; tests/test_frontend_parser.py compares the Agentica parser with what is written here. Run by `make frontend-freeze`.
; The shapes below are formulas that the Python test rebuilds; the manifests record the hash of each input.

(require racket/runtime-path
         "frontend-freeze-common.rkt"
         (only-in "frontend-lexer-common.rkt" diagnostic-line)
         "frontend-parser-common.rkt"
         "../src/source-file.rkt"
         (only-in "frontend-parser-test.rkt" generated-cases nesting-shapes function-body repeat))

(define-runtime-path parser-fixtures "fixtures/frontend/parser")

(define corpus-prefixes '("examples/" "stdlib/" "tests/fixtures/vm/"))

(define (output-of text #:first-id [first-id 0]) (string-append (parser-text text #:first-id first-id) "\n"))

(define (key-of name) (string-replace name " " "-"))

(define (write-corpus)
  (define files (corpus-paths))
  (define keys
    (sort (for/list ([path (in-hash-keys files)] #:when (ormap (lambda (prefix) (string-prefix? path prefix)) corpus-prefixes))
            path)
          string<?))
  (write-manifest "parser/corpus.sha256"
                  (for/list ([key (in-list keys)])
                    (define text (hash-ref files key))
                    (list key (output-of text) text))))

(define (write-generated)
  (define cases (generated-cases))
  (write-frozen-json "parser/generated.json" cases)
  (define entries
    (for/list ([text (in-list cases)] [n (in-naturals)])
      (list (format "case-~a" n) (output-of text) text)))
  ;; The Python test asserts that the inputs are neither all errors nor all trees.
  (printf "parser generated: ~a of ~a are errors\n"
          (count (lambda (entry) (string-prefix? (second entry) "ERROR")) entries) (length entries))
  (write-manifest "parser/generated.sha256" entries))

(define (shape-entries name->text)
  (for/list ([entry (in-list name->text)])
    (list (car entry) (output-of (cdr entry)) (cdr entry))))

(define (write-boundary)
  (write-manifest "parser/boundary.sha256"
                  (shape-entries
                   (for*/list ([count (in-range 995 1004)]
                               [shape (in-list (nesting-shapes count))]
                               #:when (member (car shape) '("parentheses" "types" "binary chain" "mixed chain")))
                     (cons (format "boundary-~a-~a" (key-of (car shape)) count) (cdr shape))))))

(define (write-nesting)
  (write-manifest "parser/nesting.sha256"
                  (shape-entries
                   (for*/list ([count (in-list '(300 900 1001 3000))] [shape (in-list (nesting-shapes count))])
                     (cons (format "nest-~a-~a" (key-of (car shape)) count) (cdr shape))))))

; The trees of the legal cases print about 1 MB each, so they are hashed and not kept.
(define (write-limits)
  (define shapes
    (list (list "mixed" 998 (lambda (n) (function-body (string-append "  y = x * x" (repeat " + x" n) "\n"))))
          (list "prefix" 998 (lambda (n) (function-body (string-append "  y = " (repeat "- " n) "x\n"))))
          (list "field" 998 (lambda (n) (function-body (string-append "  y = x" (repeat ".b" n) "\n"))))
          (list "method" 997 (lambda (n) (function-body (string-append "  y = x" (repeat ".f(1)" n) "\n"))))
          (list "nested" 988
                (lambda (n)
                  (function-body (string-append "  y = x + (x + (x + (x + (x + (x" (repeat " + x" n) ")))))\n"))))))
  (write-manifest "parser/limits.sha256"
                  (shape-entries
                   (for*/list ([shape (in-list shapes)] [n (in-list (list (second shape) (add1 (second shape))))])
                     (cons (format "limit-~a-~a" (first shape) n) ((third shape) n))))))

(define (write-large)
  (write-manifest "parser/large.sha256"
                  (shape-entries
                   (list (cons "statements" (function-body (repeat "  x = f(1, 2) + 3\n" 10000)))
                         (cons "items" (function-body (string-append "  x = [" (repeat "1, " 20000) "1]\n")))
                         (cons "branches"
                               (function-body (string-append "  if x\n  end\n"
                                                             (repeat "  if x\n    y = 1\n  elsif x\n    y = 2\n  end\n" 3000))))
                         (cons "flat"
                               (string-append* (for/list ([n (in-range 400)])
                                                 (format "def f~a(a: Int) -> Int\n  return a + ~a\nend\n\n" n n))))))))

(define (fixture-text name) (file->string (build-path parser-fixtures name)))

(define (write-ids)
  (write-frozen "parser/first-id.expected" (output-of (fixture-text "synthetic.input") #:first-id 1000))
  ; hello.input numbered from 0 is the golden hello.ast; the second file continues after its program node.
  (define first-text (parser-text (fixture-text "hello.input")))
  (define first-program-id (string->number (cadr (regexp-match #rx"^program #([0-9]+) " first-text))))
  (write-frozen "parser/continue-synthetic.expected"
                (output-of (fixture-text "synthetic.input") #:first-id (add1 first-program-id)))
  (printf "parser/first-id.expected, parser/continue-synthetic.expected\n"))

(define (write-invalid-utf8)
  (define content #"# caf\303\251\ndef \377\n")
  (define file (make-temporary-file "agentica-invalid~a.agc"))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file file #:exists 'truncate (lambda (out) (write-bytes content out)))
      (define name (path->string file))
      (write-frozen "parser/invalid-utf8.expected" (string-append (diagnostic-line (read-source-file name name)) "\n"))
      (printf "parser/invalid-utf8.expected\n"))
    (lambda () (delete-file file))))

(module+ main
  (write-corpus)
  (write-generated)
  (write-boundary)
  (write-nesting)
  (write-limits)
  (write-large)
  (write-ids)
  (write-invalid-utf8))
