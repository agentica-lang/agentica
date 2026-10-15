#lang racket

(require rackunit
         racket/runtime-path
         "frontend-lexer-common.rkt"
         "vm-diff-common.rkt"
         "../src/source-file.rkt"
         "../tools/gen-lexer-unicode.rkt")

(define-runtime-path root "..")
(define-runtime-path entry "../compiler/lex.agc")
(define-runtime-path unicode-table "../compiler/unicode_table.agc")

(define (read-text path)
  (file->string (build-path root path)))

(define (golden input)
  (file->string (golden-file input)))

(define (run-lexer bytecode paths)
  (define result
    (parameterize ([current-directory root])
      (apply run-process vm-file #:timeout run-timeout "--" (path->string bytecode) paths)))
  (check-equal? (first result) 0 (third result))
  (check-equal? (third result) "")
  (for/hash ([piece (in-list (cdr (regexp-split #rx"(?m:^== )" (second result))))])
    (define newline-at (let loop ([at 0]) (if (char=? (string-ref piece at) #\newline) at (loop (add1 at)))))
    (values (substring piece 0 newline-at) (substring piece (add1 newline-at)))))

(define (racket-files directories)
  (define base (simplify-path root))
  (sort (for*/list ([directory (in-list directories)]
                    [file (in-directory (build-path base directory))]
                    #:when (path-has-extension? file #".agc"))
          (path->string (find-relative-path base file)))
        string<?))

(define benign-fragments
  '("def " "end" "\n" "\n" " " "  " "\t" "if x" "do |x|" "x?" "a!=b" "1_000" "0.5" "..." "|>" "(" ")" "[" "]" "{" "}"
    "\"abc\"" "\"a#{" "#{" "\"" "## doc\n" "# comment\n" "99999999999999999999" "end end"))

(define risky-fragments
  (list "\r" "\r\n" "﻿" "\u0000" "\u0085" " " " " "\U0001F600" "@" ";" "Foo?" "1__0" "\\" "\"a\\q\""
        "\"\\n\\t\\#{x}\"" (string-append (make-string 400 #\9) ".5")))

(define (generated-cases)
  (parameterize ([current-pseudo-random-generator (make-pseudo-random-generator)])
    (random-seed 237)
    (define (pick fragments) (list-ref fragments (random (length fragments))))
    (for/list ([_ (in-range 300)])
      (string-append* (for/list ([_ (in-range (+ 3 (random 12)))])
                        (pick (if (< (random 10) 7) benign-fragments risky-fragments)))))))

(define (check-against-racket outputs paths)
  (for ([path (in-list paths)])
    (define text (file->string (path->complete-path path root)))
    (check-equal? (hash-ref outputs path #f) (string-append (lexer-text text) "\n") path)))

(define (with-bytecode proc) (call-with-bytecode compile-file entry proc))

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
    (unless (equal? (file->string unicode-table) (unicode-source))
      (fail "compiler/unicode_table.agc is out of date: run racket tools/gen-lexer-unicode.rkt")))

  (when (vm-built? "frontend lexer tests")
    (with-bytecode
      (lambda (work bytecode)
        (define outputs (run-lexer bytecode (map lexer-input-path inputs)))
        (test-case "the Agentica lexer matches the goldens on the VM"
          (for ([input (in-list inputs)])
            (check-equal? (hash-ref outputs (lexer-input-path input) #f) (golden input) (lexer-input-name input))))

        ; The file is read by compiler/source_file.agc before the lexer sees it (the linker test covers the details).
        (test-case "a file with invalid UTF-8 is LEX-INVALID-UTF8 at the first bad byte, as in Racket"
          (define path (path->string (build-path work "invalid.agc")))
          (call-with-output-file path (lambda (out) (write-bytes #"# caf\303\251\ndef \377\n" out)))
          (define racket (read-source-file path path))
          (check-equal? (hash-ref (run-lexer bytecode (list path)) path)
                        (string-append (diagnostic-line racket) "\n"))
          (check-regexp-match #rx"^ERROR LEX-INVALID-UTF8 11:2:5-12:2:6 " (diagnostic-line racket)))))))

(module+ slow
  (when (vm-built? "frontend lexer tests")
    (with-bytecode
      (lambda (work bytecode)
        (define live-paths (racket-files '("examples" "stdlib" "tests/fixtures/vm")))
        (define generated-paths
          (for/list ([text (in-list (generated-cases))] [n (in-naturals)])
            (define path (path->string (build-path work (format "case-~a.agc" n))))
            (display-to-file text path)
            path))
        (define outputs (run-lexer bytecode (append live-paths generated-paths)))

        (test-case "while Racket exists: the Agentica lexer matches the Racket lexer on examples/, stdlib/ and tests/fixtures/vm/"
          (check-against-racket outputs live-paths))

        (test-case "while Racket exists: the Agentica lexer matches the Racket lexer on 300 generated inputs"
          (check-against-racket outputs generated-paths))

        (test-case "a deeply nested file lexes in linear time"
          (define path (path->string (build-path work "nested.agc")))
          (display-to-file (string-append* (make-list 10000 "if x\n")) path)
          (define started (current-inexact-milliseconds))
          (define nested (run-lexer bytecode (list path)))
          (check-true (< (- (current-inexact-milliseconds) started) 5000))
          (check-against-racket nested (list path)))))))
