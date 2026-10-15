#lang racket

(require rackunit
         racket/runtime-path
         "frontend-lexer-common.rkt"
         "vm-diff-common.rkt"
         "../tools/gen-lexer-unicode.rkt")

(define-runtime-path root "..")
(define-runtime-path entry "../compiler/lex.agc")
(define-runtime-path unicode-table "../compiler/unicode_table.agc")

(define (read-text path)
  (file->string (build-path root path)))

(define (golden input)
  (file->string (golden-file input)))

(define (split-outputs output inputs)
  (define pieces (regexp-split #rx"(?m:^== )" output))
  (for/list ([piece (in-list (cdr pieces))])
    (define newline-at (let loop ([at 0]) (if (char=? (string-ref piece at) #\newline) at (loop (add1 at)))))
    (cons (substring piece 0 newline-at) (substring piece (add1 newline-at)))))

(module+ test
  (define inputs (lexer-inputs))

  (test-case "every input has a golden and no golden is left over"
    (define expected (sort (map (lambda (input) (path->string (file-name-from-path (golden-file input)))) inputs) string<?))
    (define found
      (sort (for/list ([file (in-list (directory-list (path-only (golden-file (car inputs)))))]
                       #:when (path-has-extension? file #".tokens"))
              (path->string file))
            string<?))
    (check-equal? found expected))

  (test-case "the Racket lexer matches its goldens"
    (for ([input (in-list inputs)])
      (check-equal? (string-append (lexer-text (read-text (lexer-input-path input))) "\n")
                    (golden input)
                    (lexer-input-name input))))

  (test-case "the Unicode table of the Agentica lexer is Racket's char-graphic? table"
    (check-equal? (file->string unicode-table) (unicode-source)))

  (when (vm-built? "frontend lexer tests")
    (test-case "the Agentica lexer matches the goldens on the VM"
      (define work (make-temporary-directory "agentica-frontend~a"))
      (dynamic-wind
        void
        (lambda ()
          (define bytecode (build-path work "lex.agcb"))
          (compile-file entry bytecode)
          (define result
            (parameterize ([current-directory root])
              (apply run-process vm-file #:timeout run-timeout
                     "--" (path->string bytecode) (map lexer-input-path inputs))))
          (check-equal? (first result) 0 (third result))
          (check-equal? (third result) "")
          (define outputs (split-outputs (second result) inputs))
          (check-equal? (map car outputs) (map lexer-input-path inputs))
          (for ([input (in-list inputs)] [output (in-list outputs)])
            (check-equal? (cdr output) (golden input) (lexer-input-name input))))
        (lambda () (delete-directory/files work))))))
