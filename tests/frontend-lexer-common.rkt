#lang racket

(require racket/runtime-path
         "../src/diagnostic.rkt"
         "../src/lexer.rkt"
         "../src/source.rkt"
         "../src/token.rkt")

(provide lexer-text
         quote-text
         span-text
         float-bits
         diagnostic-line
         lexer-inputs
         (struct-out lexer-input)
         golden-file
         write-lexer-goldens)

(struct lexer-input (name path))

(define-runtime-path root "..")
(define-runtime-path fixtures "fixtures/frontend/lexer")

(define (quote-text text)
  (define out (open-output-string))
  (write-char #\" out)
  (for ([char (in-string text)])
    (define code (char->integer char))
    (cond
      [(char=? char #\") (write-string "\\\"" out)]
      [(char=? char #\\) (write-string "\\\\" out)]
      [(char=? char #\newline) (write-string "\\n" out)]
      [(char=? char #\return) (write-string "\\r" out)]
      [(char=? char #\tab) (write-string "\\t" out)]
      [(or (< code 32) (> code 126))
       (write-string (string-append "\\u{" (string-upcase (number->string code 16)) "}") out)]
      [else (write-char char out)]))
  (write-char #\" out)
  (get-output-string out))

(define (position-text position)
  (format "~a:~a:~a"
          (source-position-offset position)
          (source-position-line position)
          (source-position-column position)))

(define (span-text span)
  (string-append (position-text (source-span-start span)) "-" (position-text (source-span-end span))))

(define (float-bits value)
  (integer-bytes->integer (real->floating-point-bytes value 8) #t))

(define (value-text tok)
  (define value (token-value tok))
  (cond
    [(not value) "-"]
    [(string? value) (if (equal? value (token-lexeme tok)) "=" (quote-text value))]
    [(exact-integer? value) (number->string value)]
    [(flonum? value) (format "bits:~a" (float-bits value))]
    [(doc-block? value)
     (format "doc ~a ~a" (quote-text (doc-block-text value)) (doc-block-next value))]
    [else (error 'lexer-text "unexpected token value ~s" value)]))

(define (token-line tok)
  (string-join (list (symbol->string (token-kind tok))
                     (span-text (token-span tok))
                     (quote-text (token-lexeme tok))
                     (value-text tok))
               " "))

(define (diagnostic-line problem)
  (string-join (list "ERROR"
                     (symbol->string (diagnostic-code problem))
                     (span-text (diagnostic-span problem))
                     (quote-text (diagnostic-message problem))
                     (if (diagnostic-help problem) (quote-text (diagnostic-help problem)) "-"))
               " "))

(define (lexer-text text)
  (define result (lex (source "input.agc" text)))
  (if (diagnostic? result)
      (diagnostic-line result)
      (string-join (map token-line result) "\n")))

(define (lexer-inputs)
  (for/list ([file (in-list (sort (directory-list fixtures) path<?))]
             #:when (path-has-extension? file #".input"))
    (define name (path->string (path-replace-extension file #"")))
    (lexer-input name (string-append "tests/fixtures/frontend/lexer/" (path->string file)))))

(define (golden-file input)
  (build-path fixtures (string-append (lexer-input-name input) ".tokens")))

(define (write-lexer-goldens)
  (define inputs (lexer-inputs))
  (for ([input (in-list inputs)])
    (define text (file->string (build-path root (lexer-input-path input))))
    (display-to-file (string-append (lexer-text text) "\n") (golden-file input) #:exists 'truncate/replace))
  (define expected (map (lambda (input) (path->string (file-name-from-path (golden-file input)))) inputs))
  (for ([file (in-list (directory-list fixtures))]
        #:when (and (path-has-extension? file #".tokens")
                    (not (member (path->string file) expected))))
    (delete-file (build-path fixtures file)))
  (printf "frontend lexer: ~a goldens\n" (length inputs)))

(module+ main
  (write-lexer-goldens))
