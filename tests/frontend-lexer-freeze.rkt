#lang racket

; Freezes the live comparisons of tests/frontend-lexer-test.rkt: the Racket lexer over the corpus, the 300 generated
; inputs, the deeply nested files and a file with invalid UTF-8. tests/test_frontend_lexer.py compares the Agentica
; lexer with what is written here. Run by `make frontend-freeze`.

(require "frontend-freeze-common.rkt"
         "frontend-lexer-common.rkt"
         "../src/source-file.rkt"
         (only-in "../tools/gen-lexer-unicode.rkt" graphic-ranges)
         (only-in "frontend-lexer-test.rkt" generated-cases))

(define corpus-prefixes '("examples/" "stdlib/" "tests/fixtures/vm/"))

(define (output-of text) (string-append (lexer-text text) "\n"))

(define (write-corpus)
  (define files (corpus-paths))
  (define keys
    (sort (for/list ([path (in-hash-keys files)] #:when (ormap (lambda (prefix) (string-prefix? path prefix)) corpus-prefixes))
            path)
          string<?))
  (write-manifest "lexer/corpus.sha256"
                  (for/list ([key (in-list keys)])
                    (define text (hash-ref files key))
                    (list key (output-of text) text))))

(define (write-generated)
  (define cases (generated-cases))
  (write-frozen-json "lexer/generated.json" cases)
  (write-manifest "lexer/generated.sha256"
                  (for/list ([text (in-list cases)] [n (in-naturals)])
                    (list (format "case-~a" n) (output-of text) text))))

(define (nested depth) (string-append* (make-list depth "if x\n")))

(define (write-nested)
  (write-manifest "lexer/nested.sha256"
                  (for/list ([depth (in-list '(4000 10000))])
                    (list (format "nested-~a" depth) (output-of (nested depth)) (nested depth)))))

; The bytes are the ones the Python test writes: a valid comment, then a byte that is not UTF-8.
(define (write-invalid-utf8)
  (define content #"# caf\303\251\ndef \377\n")
  (define file (make-temporary-file "agentica-invalid~a.agc"))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file file #:exists 'truncate (lambda (out) (write-bytes content out)))
      (define name (path->string file))
      (write-frozen "lexer/invalid-utf8.expected" (string-append (diagnostic-line (read-source-file name name)) "\n"))
      (printf "lexer/invalid-utf8.expected\n"))
    (lambda () (delete-file file))))

;; The ranges of code points the Racket lexer takes for graphic characters (char-graphic? and not char-blank?), which
;; compiler/unicode_table.agc must list: low and high of each range, one line each.
(define (write-graphic-ranges)
  (write-frozen "lexer/graphic-ranges.expected"
                (string-append* (for/list ([range (in-list (graphic-ranges))])
                                  (format "~a ~a\n" (car range) (cdr range)))))
  (printf "lexer/graphic-ranges.expected\n"))

(module+ main
  (write-graphic-ranges)
  (write-corpus)
  (write-generated)
  (write-nested)
  (write-invalid-utf8))
