#lang racket

; The Agentica bytecode writer (compiler/bytecode.agc) against the Racket writer (src/bytecode.rkt): the .agcb
; bytes of the same program must be equal, on the lowering fixtures, examples/ and the fixtures of
; tests/fixtures/frontend/bytecode/ in the fast tier, and on the whole corpus in the slow tier. The Racket bytes are
; made in this process, from the same pipeline `agentica compile` runs.

(require (except-in rackunit check)
         racket/runtime-path
         "frontend-lower-common.rkt"
         (only-in "frontend-lexer-common.rkt" call-with-bytecode)
         (only-in "frontend-modules-common.rkt" default-env env-arguments with-env stdlib-folder)
         "vm-diff-common.rkt"
         "../src/bytecode.rkt"
         "../src/checker.rkt"
         "../src/diagnostic.rkt"
         "../src/modules.rkt"
         "../src/lower.rkt")

(define-runtime-path root "..")
(define-runtime-path entry "../compiler/bytecode.agc")
(define-runtime-path tables "../compiler/bytecode_tables.agc")
(define-runtime-path extra-fixtures "fixtures/frontend/bytecode")
(define-runtime-path version-file "../src/version.rkt")

; What the Racket front end gives for a file: its program (and the bytes) or the ERROR line of the text form of
; lowering (tests/frontend-lower-common.rkt), which is what the Agentica runner prints for a failure before the
; writer. A diagnostic of the writer itself is a test error: no program of the corpus reaches one.
(struct compiled (program bytes line))

(define (racket-compile path)
  (define result
    (with-env default-env
      (lambda ()
        (define linked (load-program path))
        (cond
          [(diagnostic? linked) linked]
          [else
           (define types (make-hasheq))
           (define checked (check linked #:types types))
           (cond
             [(diagnostic? checked) checked]
             [else
              (define ir (lower checked types))
              (if (diagnostic? ir) ir (ir->bytecode ir))])]))))
  (cond
    [(bc-program? result)
     (define data (write-bytecode result))
     (when (diagnostic? data) (error 'frontend-bytecode "~a: ~a" path (format-diagnostic data)))
     (compiled result data #f)]
    [(regexp-match? #rx"^BYTECODE-" (symbol->string (diagnostic-code result)))
     (error 'frontend-bytecode "~a: ~a" path (format-diagnostic result))]
    [else (compiled #f #f (lower-text path))]))

; The fixtures of this test: those of the lowering, and the ones only the writer needs.
(define (bytecode-paths)
  (append (map (lambda (input) (path->string (simplify-path (lower-input-root input)))) (lower-inputs))
          (for/list ([file (in-list (sort (directory-list extra-fixtures #:build? #t) path<?))]
                     #:when (path-has-extension? file #".agc"))
            (path->string (simplify-path file)))))

(define (with-bytecode proc) (call-with-bytecode compile-file entry proc))

; Runs compiler/bytecode.agc once over the paths, writing the file of each under work/out. Gives, by path, the
; line the runner printed and the file it wrote.
(define (agentica-compile bytecode work paths #:timeout [timeout 600])
  (define folder (build-path work "out"))
  (make-directory* folder)
  (define outputs
    (for/list ([path (in-list paths)] [n (in-naturals)]) (path->string (build-path folder (format "~a.agcb" n)))))
  (define result
    (parameterize ([current-directory root])
      (apply run-process vm-file #:timeout timeout "--" (path->string bytecode)
             (string-append "--stdlib=" (path->string stdlib-folder))
             (append (env-arguments default-env)
                     (append-map (lambda (path output) (list path "-o" output)) paths outputs)))))
  (check-equal? (first result) 0 (third result))
  (check-equal? (third result) "")
  (define lines
    (for/hash ([piece (in-list (cdr (regexp-split #rx"(?m:^== )" (second result))))])
      (define parts (regexp-match #rx"^([^\n]*)\n(.*)\n$" piece))
      (values (cadr parts) (caddr parts))))
  (for/hash ([path (in-list paths)] [output (in-list outputs)])
    (values path (cons (hash-ref lines path #f) output))))

; #f when the bytes are equal, else where they first differ: a failure message that does not print megabytes.
(define (first-difference expected actual)
  (cond
    [(equal? expected actual) #f]
    [else
     (define shared (min (bytes-length expected) (bytes-length actual)))
     (define at (or (for/first ([i (in-range shared)] #:unless (= (bytes-ref expected i) (bytes-ref actual i))) i) shared))
     (format "first difference at byte ~a, lengths ~a (Racket) and ~a (Agentica)"
             at (bytes-length expected) (bytes-length actual))]))

(define (agentica-matches-racket results paths)
  (for ([path (in-list paths)])
    (define expected (racket-compile path))
    (define got (hash-ref results path))
    (cond
      [(compiled-bytes expected)
       (check-equal? (car got) (format "wrote ~a bytes" (bytes-length (compiled-bytes expected))) path)
       (check-equal? (and (file-exists? (cdr got)) (first-difference (compiled-bytes expected) (file->bytes (cdr got))))
                     #f path)]
      [else
       (check-equal? (car got) (compiled-line expected) path)
       (check-false (file-exists? (cdr got)) path)])))

; The opcode numbers and names of compiler/bytecode_tables.agc: the pairs of its OPCODES map.
(define (agentica-opcodes)
  (define text (file->string tables))
  (define at (car (regexp-match-positions #rx"OPCODES = {" text)))
  (define end (car (regexp-match-positions #rx"\n}" text (cdr at))))
  (for/list ([pair (in-list (regexp-match* #rx"\"([^\"]+)\": ([0-9]+)" (substring text (cdr at) (car end))
                                           #:match-select cdr))])
    (cons (string->symbol (car pair)) (string->number (cadr pair)))))

(define (agentica-constant name)
  (cadr (regexp-match (pregexp (format "(?m:^export ~a = ([^\n]+))" name)) (file->string tables))))

(module+ test
  (define paths (append (bytecode-paths) (agc-files-in "examples")))
  (define programs (filter values (map (lambda (path) (compiled-program (racket-compile path))) paths)))

  (test-case "the Agentica opcode table is the one of src/bytecode.rkt"
    (check-equal? (agentica-opcodes) (for/list ([op (in-list opcodes)] [n (in-naturals)]) (cons op n))))

  (test-case "the Agentica header constants are those of the Racket writer"
    (check-equal? (agentica-constant "FORMAT_VERSION") "5")
    (check-equal? (agentica-constant "VERSION") (format "~s" (dynamic-require version-file 'version)))
    (define data (write-bytecode (car programs)))
    (check-equal? (subbytes data 0 8) (bytes-append #"AGCB" (integer->integer-bytes 5 4 #f #f))))

  (test-case "the programs have an instruction of every opcode"
    (define seen (make-hash))
    (for* ([program (in-list programs)] [function (in-list (bc-program-functions program))]
           [instr (in-vector (bc-function-code function))])
      (hash-set! seen (car instr) #t))
    (for ([op (in-list opcodes)] [n (in-naturals)])
      (check-true (hash-ref seen n #f) (symbol->string op))))

  (test-case "the programs fill every section of the file"
    (define (some? count) (ormap (lambda (program) (> (count program) 0)) programs))
    (check-true (some? (lambda (p) (length (bc-program-sources p)))) "sources")
    (check-true (ormap (lambda (p) (> (length (bc-program-sources p)) 1)) programs) "more than one source")
    (for ([section (list (cons "spans" (compose vector-length bc-program-spans))
                         (cons "constants" (compose vector-length bc-program-constants))
                         (cons "structs" (compose length bc-program-structs))
                         (cons "types" (compose vector-length bc-program-types))
                         (cons "decodable" (compose length bc-program-decodable))
                         (cons "enums" (compose length bc-program-enums))
                         (cons "updates" (compose length bc-program-updates))
                         (cons "globals" bc-program-globals)
                         (cons "builtins" (compose length bc-program-builtins))
                         (cons "functions" (compose length bc-program-functions)))])
      (check-true (some? (cdr section)) (car section)))
    (define constants (append-map (lambda (p) (vector->list (bc-program-constants p))) programs))
    (for ([kind (list (cons "void" void?) (cons "nil" (lambda (v) (eq? v 'nil))) (cons "false" (lambda (v) (eq? v #f)))
                      (cons "true" (lambda (v) (eq? v #t))) (cons "int" exact-integer?) (cons "float" flonum?)
                      (cons "string" string?))])
      (check-true (ormap (cdr kind) constants) (car kind)))
    (check-true (ormap (lambda (v) (and (string? v) (not (= (string-length v) (bytes-length (string->bytes/utf-8 v)))))) constants)
                "a string with a multi-byte character"))

  (when (vm-built? "frontend bytecode tests")
    (with-bytecode
      (lambda (work bytecode)
        (define results (agentica-compile bytecode work paths))

        (test-case "the Agentica writer writes the bytes of the Racket writer"
          (agentica-matches-racket results paths))

        (test-case "a check failure and an import failure print their ERROR line and write no file"
          (define failures
            (for/list ([path (in-list paths)] #:when (regexp-match? #rx"/error-" path)) (car (hash-ref results path))))
          (check-equal? (length failures) 2)
          (check-true (ormap (lambda (line) (regexp-match? #rx"^ERROR CHECK-[A-Z-]+ " line)) failures))
          (check-true (ormap (lambda (line) (regexp-match? #rx"^ERROR CHECK-IMPORT-IO " line)) failures)))

        (test-case "the VM runs the Agentica file as it runs the Racket file"
          (for ([name (in-list '("basics" "case" "closures" "collections" "enums" "results" "structs" "unicode"))])
            (define path (for/first ([path (in-list paths)] #:when (regexp-match? (regexp (format "/~a\\.agc$" name)) path)) path))
            (check-true (string? path) name)
            (define racket-file (build-path work (string-append name "-racket.agcb")))
            (display-to-file (compiled-bytes (racket-compile path)) racket-file #:exists 'truncate/replace)
            (define (run file)
              (parameterize ([current-directory root])
                (run-process vm-file #:timeout run-timeout "--" (if (path? file) (path->string file) file))))
            (define expected (run racket-file))
            (check-equal? (first expected) 0 name)
            (check-equal? (run (cdr (hash-ref results path))) expected name)))))))

(module+ slow
  (when (vm-built? "frontend bytecode tests")
    (with-bytecode
      (lambda (work bytecode)
        (define (compare paths)
          (agentica-matches-racket (agentica-compile bytecode work paths #:timeout 1800) paths))

        (test-case "while Racket exists: the Agentica writer matches the Racket writer on tests/fixtures/vm/"
          (define paths (agc-files-in "tests/fixtures/vm"))
          (check-true (> (length paths) 200))
          (compare paths))

        (test-case "while Racket exists: the Agentica writer matches the Racket writer on every std/ module and the compiler"
          (define paths (append (std-wrapper-paths work) (agc-files-in "compiler")))
          (check-true (> (length paths) 50))
          (compare paths))

        (test-case "trees at the nesting limit and a generated program are written with equal bytes"
          (define paths
            (cons (write-file (build-path work "generated.agc") (generated-program 300))
                  (for/list ([entry (in-list (deep-cases))])
                    (write-file (build-path work "deep" (format "~a.agc" (car entry))) (cdr entry)))))
          (compare paths))))))
