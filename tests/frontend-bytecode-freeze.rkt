#lang racket

; Freezes the live comparisons of tests/frontend-bytecode-test.rkt: the .agcb bytes of the Racket writer for the lowering
; fixtures, examples/, tests/fixtures/vm/, every std/ module, the compiler, trees at the nesting limit, a program of 300
; functions, programs with spans past 65535, the lines of the limit scenarios, and the opcode table.
; tests/test_frontend_bytecode.py compares the Agentica writer with what is written here. Run by `make frontend-freeze`.
; A manifest line holds the hash of what a compile gives: the line the runner prints and the hash of the file it writes
; (or `no file`).

(require json
         "frontend-freeze-common.rkt"
         "vm-diff-common.rkt"
         (only-in "frontend-lower-common.rkt" deep-cases generated-program)
         "../src/bytecode.rkt"
         (prefix-in test: "frontend-bytecode-test.rkt"))

;; The header ends with the Agentica version (magic, format version, the length of the version and its bytes). A release
;; changes it, and the freeze must not change with it, so the size and the hash are those of the file without the length
;; and the text of the version. The Python test does the same (tests/test_frontend_bytecode.py, without_version).
(define (without-version data)
  (bytes-append (subbytes data 0 8) (subbytes data (+ 12 (integer-bytes->integer data #f #f 8 12)))))

;; What one compile gives, as the Python test builds it: `wrote N bytes` and the hash of the bytes without the version, or
;; the ERROR line of the first stage that failed and `no file`.
(define (output-of path)
  (define compiled (test:racket-compile path))
  (cond
    [(test:compiled-bytes compiled)
     (define body (without-version (test:compiled-bytes compiled)))
     (format "wrote ~a bytes\n~a\n" (bytes-length body) (sha256-hex body))]
    [else (format "~a\nno file\n" (test:compiled-line compiled))]))

;; The lowering fixtures: a NAME.agc file or a folder NAME with a root.agc.
(define (lower-fixture-keys files)
  (define prefix "tests/fixtures/frontend/lower/")
  (sort (for/list ([key (in-hash-keys files)]
                   #:when (and (string-prefix? key prefix)
                               (let ([rest (substring key (string-length prefix))])
                                 (or (not (string-contains? rest "/")) (regexp-match? #rx"^[^/]*/root[.]agc$" rest)))))
          key)
        string<?))

(define (write-corpus)
  (with-corpus
    (lambda (dir)
      (define files (corpus-paths))
      (define (path-entries keys)
        (for/list ([key (in-list keys)])
          (list key (output-of (path->string (build-path dir key))) (hash-ref files key))))
      (write-manifest "bytecode/fast.sha256"
                      (path-entries (append (lower-fixture-keys files)
                                            (direct-files files "tests/fixtures/frontend/bytecode")
                                            (direct-files files "examples"))))
      (write-manifest "bytecode/vm.sha256" (path-entries (direct-files files "tests/fixtures/vm")))
      (write-manifest "bytecode/std-compiler.sha256"
                      (append (program-entries dir "std" (std-wrappers files) output-of)
                              (path-entries (direct-files files "compiler")))))))

(define (write-deep)
  (call-with-temporary-folder
   (lambda (dir)
     (write-manifest "bytecode/deep.sha256"
                     (program-entries dir "deep"
                                      (cons (cons "generated" (generated-program 300))
                                            (for/list ([entry (in-list (deep-cases))])
                                              (cons (format "deep-~a" (car entry)) (cdr entry))))
                                      output-of)))))

;; Programs with a line or a column past 65535, built as wide_span_programs in tests/frontend_cases.py: the Python test
;; checks the hash of their text against the manifest.
(define (write-wide-spans)
  (call-with-temporary-folder
   (lambda (dir)
     (write-manifest "bytecode/wide-spans.sha256"
                     (program-entries
                      dir "wide"
                      (list (cons "lines"
                                  (string-append (make-string 65600 #\newline) "def main() -> Void\n  puts(\"x\")\nend\n"))
                            (cons "columns"
                                  (string-append "def main() -> Void\n  puts(\"" (make-string 65600 #\x) "\")\nend\n")))
                      output-of)))))

;; The lines the Agentica fixture prints for its scenarios, as the Racket writer gives them.
(define (write-limits)
  (define (lines constant)
    (string-append* (for/list ([name (in-list (test:scenario-names constant))])
                      (string-append (test:racket-limits-line name) "\n"))))
  (write-frozen "bytecode/limits.expected" (lines "SCENARIOS"))
  (write-frozen "bytecode/limits-slow.expected" (lines "SLOW_SCENARIOS"))
  (printf "bytecode/limits.expected, bytecode/limits-slow.expected\n"))

(define (write-opcodes)
  (write-frozen "bytecode/opcodes.expected"
                (string-append* (for/list ([op (in-list opcodes)] [n (in-naturals)]) (format "~a ~a\n" op n))))
  (printf "bytecode/opcodes.expected\n"))

;; What the VM prints for the Racket file of two programs, which the Agentica file must print too.
(define (write-runs)
  (define names '("basics" "unicode"))
  (with-corpus
    (lambda (dir)
      (define runs
        (for/list ([name (in-list names)])
          (define path
            (path->string
             (if (equal? name "basics")
                 (build-path dir "tests/fixtures/frontend/lower/basics.agc")
                 (build-path dir "tests/fixtures/frontend/bytecode/unicode.agc"))))
          (define file (build-path dir (string-append name "-racket.agcb")))
          (display-to-file (test:compiled-bytes (test:racket-compile path)) file #:exists 'truncate/replace)
          (define result
            (parameterize ([current-directory repo-root])
              (run-process vm-file #:timeout run-timeout "--" (path->string file))))
          (unless (eq? (first result) 0) (error 'write-runs "~a exits with ~a" name (first result)))
          (format "== ~a\nexit ~a\nstdout ~a\nstderr ~a\n" name (first result) (jsexpr->string (second result))
                  (jsexpr->string (third result)))))
      (write-frozen "bytecode/runs.expected" (string-append* runs))
      (printf "bytecode/runs.expected\n"))))

(module+ main
  (write-opcodes)
  (write-limits)
  (write-corpus)
  (write-deep)
  (write-wide-spans)
  (write-runs))
