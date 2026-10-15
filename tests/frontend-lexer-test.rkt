#lang racket

(require rackunit
         racket/runtime-path
         "frontend-corpus-common.rkt"
         "frontend-lexer-common.rkt"
         "vm-diff-common.rkt"
         "../src/source-file.rkt")

(define-runtime-path root "..")
(define-runtime-path entry "../compiler/lex.agc")

; The generated inputs and the nesting check are read by the writer of the frozen comparisons (tests/frontend-lexer-freeze.rkt).
(provide generated-cases)

(define (read-text path)
  (file->string (build-path root path)))

(define (golden input)
  (file->string (golden-file input)))

(define (run-lexer bytecode paths #:flags [flags '()])
  (run-stage-sections bytecode paths #:flags flags))

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

;; Lexes `depth` nested `if x` lines under a step budget instead of a clock, so
;; the check is deterministic on a loaded runner. The linear lexer costs about
;; 1,000 steps per line and the budget allows 3,000, so a scan of the whole frame
;; stack per line fails it.
(define steps-per-line 3000)

(define (check-nested-linear bytecode work depth)
  (define path (path->string (build-path work (format "nested-~a.agc" depth))))
  (display-to-file (string-append* (make-list depth "if x\n")) path #:exists 'truncate)
  (define nested
    (run-lexer bytecode (list path) #:flags (list "--max-steps" (number->string (* depth steps-per-line)))))
  (check-against-racket nested (list path)))

(define (with-bytecode proc) (call-with-bytecode compile-file entry proc))

(module+ test
  (define inputs (lexer-inputs))

  (test-case "the Racket lexer matches its goldens"
    (for ([input (in-list inputs)])
      (check-equal? (string-append (lexer-text (read-text (lexer-input-path input))) "\n")
                    (golden input)
                    (lexer-input-name input))))

  (when (vm-built? "frontend lexer tests")
    (with-bytecode
      (lambda (work bytecode)
        ; The file is read by compiler/source_file.agc before the lexer sees it (the linker test covers the details).
        (test-case "a file with invalid UTF-8 is LEX-INVALID-UTF8 at the first bad byte, as in Racket"
          (define path (path->string (build-path work "invalid.agc")))
          (call-with-output-file path (lambda (out) (write-bytes #"# caf\303\251\ndef \377\n" out)))
          (define racket (read-source-file path path))
          (check-equal? (hash-ref (run-lexer bytecode (list path)) path)
                        (string-append (diagnostic-line racket) "\n"))
          (check-regexp-match #rx"^ERROR LEX-INVALID-UTF8 11:2:5-12:2:6 " (diagnostic-line racket)))
        (test-case "a deeply nested file lexes in a linear number of steps"
          (check-nested-linear bytecode work 4000))))))

(module+ slow
  (when (vm-built? "frontend lexer tests")
    (with-bytecode
      (lambda (work bytecode)
        (define live-paths (agc-files-under '("examples" "stdlib" "tests/fixtures/vm")))
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

        (test-case "a deeply nested file lexes in a linear number of steps"
          (check-nested-linear bytecode work 10000))))))
