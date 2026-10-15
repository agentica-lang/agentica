#lang racket

; The Agentica bytecode writer (compiler/bytecode.agc) against the Racket writer (src/bytecode.rkt): the .agcb
; bytes of the same program must be equal, on the lowering fixtures, examples/ and the fixtures of
; tests/fixtures/frontend/bytecode/ in the fast tier, and on the whole corpus in the slow tier. The Racket bytes are
; made in this process, from the same pipeline `agentica compile` runs.

(require (except-in rackunit check)
         racket/runtime-path
         "frontend-lower-common.rkt"
         "frontend-corpus-common.rkt"
         (only-in "frontend-modules-common.rkt" default-env env-arguments with-env stdlib-folder)
         "vm-diff-common.rkt"
         "../src/bytecode.rkt"
         "../src/checker.rkt"
         "../src/diagnostic.rkt"
         "../src/modules.rkt"
         "../src/lower.rkt"
         "../src/source.rkt")

(define-runtime-path root "..")
(define-runtime-path entry "../compiler/bytecode.agc")
(define-runtime-path tables "../compiler/bytecode_tables.agc")
(define-runtime-path extra-fixtures "fixtures/frontend/bytecode")
(define-runtime-path version-file "../src/version.rkt")
(define-runtime-path limits-fixture "fixtures/frontend/limits/limits.agc")

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
; Each call writes into a folder of its own, so a file of an earlier call is never taken for the output of a failure.
(define runs 0)

(define (agentica-compile bytecode work paths #:timeout [timeout 600])
  (set! runs (add1 runs))
  (define folder (build-path work (format "out~a" runs)))
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
     (define at
       (or (for/first ([i (in-range shared)] #:unless (= (bytes-ref expected i) (bytes-ref actual i))) i)
           shared))
     (format "first difference at byte ~a, lengths ~a (Racket) and ~a (Agentica)"
             at (bytes-length expected) (bytes-length actual))]))

(define (agentica-matches-racket results paths)
  (for ([path (in-list paths)])
    (define expected (racket-compile path))
    (define got (hash-ref results path))
    (cond
      [(compiled-bytes expected)
       (check-equal? (car got) (format "wrote ~a bytes" (bytes-length (compiled-bytes expected))) path)
       (check-equal? (and (file-exists? (cdr got))
                          (first-difference (compiled-bytes expected) (file->bytes (cdr got))))
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


; The programs of tests/fixtures/frontend/limits/limits.agc, built for the Racket writer: lowered programs no source
; file gives, which reach the limits of the format and the BYTECODE-INTERNAL paths. Each name has the program of the
; Agentica fixture of that name and prints the same line (the size and a checksum of the bytes, or the code and place
; of the problem, with the message of a BYTECODE-LIMIT).
(define first-file (source "a.agc" "one\n"))
(define second-file (source "b.agc" "é\n"))

(define (span-at file line)
  (source-span file (source-position 0 line 1) (source-position 0 line 5)))

(define (instr op args file line) (ir-instr op args (list (span-at file line))))

(define (function slots body) (ir-function "f" 0 0 slots body (span-at second-file 30)))

(define (program structs enums functions globals)
  (ir-program (list first-file second-file) structs enums functions 0 globals (span-at first-file 1)))

(define (with-body slots body) (program '() '() (list (function slots body)) 0))

(define (structs-named count)
  (for/list ([index (in-range count)]) (ir-struct (format "S~a" index) '() #f)))

(define (decodable name types) (ir-struct name '("f") types))

(define (deep levels) (for/fold ([type 'Int]) ([_ (in-range levels)]) (list 'List type)))

(define (updates count)
  (append (for/list ([index (in-range count)]) (instr 'struct-with (list 0 1 index (list 0)) second-file 31))
          (list (instr 'return '(0) second-file 32))))

(define (limits-scenario name)
  (match name
    ["globals-ok" (program '() '() '() 65535)]
    ["globals-over" (program '() '() '() 65536)]
    ["structs-ok" (program (structs-named 65535) '() '() 0)]
    ["structs-over" (program (structs-named 65536) '() '() 0)]
    ["variants-over"
     (program '() (list (ir-enum "E" (for/list ([index (in-range 65536)]) (cons (format "V~a" index) 0)))) '() 0)]
    ["fields-over" (program (list (ir-struct "Big" (make-list 65536 "x") #f)) '() '() 0)]
    ["payload-over" (program '() (list (ir-enum "E" (list (cons "V" 65536)))) '() 0)]
    ["registers-ok" (with-body 65535 (list (instr 'return '(0) second-file 31)))]
    ["registers-over" (with-body 65536 (list (instr 'return '(0) second-file 31)))]
    ["types-over"
     (program (append (structs-named 65534)
                      (list (decodable "J" (append '(Int Float Bool String)
                                                   (for/list ([index (in-range 65534)])
                                                     (list 'Struct (format "S~a" index)))
                                                   (list '(Struct "J"))))))
              '() '() 0)]
    ["types-deep-ok" (program (list (decodable "J" (list (deep 1024)))) '() '() 0)]
    ["types-deep-over" (program (list (decodable "J" (list (deep 1025)))) '() '() 0)]
    ["updates-ok" (with-body 2 (updates 65535))]
    ["updates-over" (with-body 2 (updates 65536))]
    ["steps-merged"
     (with-body 2 (append (list (ir-label 7))
                          (for/list ([index (in-range 65537)]) (instr 'step '() second-file (+ 31 (modulo index 3))))
                          (list (ir-label 8)
                                (instr 'step '() second-file 40)
                                (instr 'jump '(7) second-file 41)
                                (instr 'jump-if-false '(0 8) second-file 41)
                                (instr 'return '(0) second-file 42))))]
    ["labels"
     (with-body 2 (list (instr 'step '() second-file 31) (instr 'jump '(3) second-file 32) (ir-label 2) (ir-label 3)
                        (instr 'jump-if-true '(1 2) first-file 33) (instr 'return '(1) second-file 34)))]
    ["unknown-op" (with-body 2 (list (instr 'teleport '(0 0 0) second-file 31)))]
    ["missing-label" (with-body 2 (list (instr 'jump '(9) second-file 31)))]
    ["operand-range" (with-body 2 (list (instr 'move '(0 70000) second-file 31)))]
    ["operand-wide" (with-body 2 (list (instr 'call '(0 4294967296) second-file 31)))]
    ["operand-count"
     (with-body 2 (list (instr 'add-i '(0 1) second-file 31) (instr 'list '(0 1 2 3 4) second-file 32)))]
    ["operand-short" (with-body 2 (list (instr 'move '(0) second-file 31)))]))

(define (checksum data)
  (for/fold ([total 0]) ([byte (in-bytes data)]) (modulo (+ (* total 31) byte) 1000000007)))

(define (racket-limits-line name)
  (define ir (limits-scenario name))
  (define result
    (with-handlers ([exn:fail? (lambda (failure) (error 'frontend-bytecode "~a: ~a" name (exn-message failure)))])
      (let ([code (ir->bytecode ir)]) (if (diagnostic? code) code (write-bytecode code)))))
  (cond
    [(bytes? result) (format "~a ok ~a ~a" name (bytes-length result) (checksum result))]
    [else
     (define span (diagnostic-span result))
     (define line
       (format "~a ERROR ~a ~a:~a-~a:~a file=~a" name (diagnostic-code result)
               (source-position-line (source-span-start span)) (source-position-column (source-span-start span))
               (source-position-line (source-span-end span)) (source-position-column (source-span-end span))
               (source-name (source-span-source span))))
     (if (eq? (diagnostic-code result) 'BYTECODE-LIMIT)
         (string-append line " " (diagnostic-message result))
         line)]))

; The scenario names of the Agentica fixture: the strings of its SCENARIOS constant (or SLOW_SCENARIOS).
(define (scenario-names constant)
  (define text (file->string limits-fixture))
  (define at (car (regexp-match-positions (regexp (format "(?m:^~a = \\[)" constant)) text)))
  (define end (car (regexp-match-positions #rx"\\]" text (cdr at))))
  (map cadr (regexp-match* #rx"\"([^\"]+)\"" (substring text (cdr at) (car end)) #:match-select values)))

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
    (define (multi-byte? v) (and (string? v) (not (= (string-length v) (bytes-length (string->bytes/utf-8 v))))))
    (check-true (ormap multi-byte? constants) "a string with a multi-byte character"))

  (when (vm-built? "frontend bytecode tests")
    (call-with-bytecode
     compile-file limits-fixture
     (lambda (work bytecode)
       (test-case "the Agentica writer reaches the limits and the internal errors as the Racket writer does"
         (define result
           (parameterize ([current-directory root])
             (run-process vm-file #:timeout 300 "--" (path->string bytecode))))
         (check-equal? (first result) 0 (third result))
         (define names (scenario-names "SCENARIOS"))
         (check-true (> (length names) 15))
         (check-equal? (string-split (second result) "\n") (map racket-limits-line names)))))

    (with-bytecode
      (lambda (work bytecode)
        (define results (agentica-compile bytecode work paths))

        (test-case "the Agentica writer writes the bytes of the Racket writer"
          (agentica-matches-racket results paths))

        (test-case "a check failure and an import failure print their ERROR line and write no file"
          ; The files are checked in "the Agentica writer writes the bytes of the Racket writer", where each run has a
          ; folder of its own: no file of a failure exists.
          (define failures
            (for/list ([path (in-list paths)] #:when (regexp-match? #rx"/error-" path)) (car (hash-ref results path))))
          (check-equal? (length failures) 2)
          (check-true (ormap (lambda (line) (regexp-match? #rx"^ERROR CHECK-[A-Z-]+ " line)) failures))
          (check-true (ormap (lambda (line) (regexp-match? #rx"^ERROR CHECK-IMPORT-IO " line)) failures)))

        (test-case "the VM runs the Agentica file as it runs the Racket file"
          (for ([name (in-list '("basics" "unicode"))])
            (define path
              (for/first ([path (in-list paths)] #:when (regexp-match? (regexp (format "/~a\\.agc$" name)) path))
                path))
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

        (test-case "while Racket exists: the Agentica writer matches the Racket writer on std/ and compiler/"
          (define paths (append (std-wrapper-paths work) (agc-files-in "compiler")))
          (check-true (> (length paths) 50))
          (compare paths))

        (test-case "trees at the nesting limit and a generated program are written with equal bytes"
          (define paths
            (cons (write-file (build-path work "generated.agc") (generated-program 300))
                  (for/list ([entry (in-list (deep-cases))])
                    (write-file (build-path work "deep" (format "~a.agc" (car entry))) (cdr entry)))))
          (compare paths)))))

  (when (vm-built? "frontend bytecode tests")
    (call-with-bytecode
     compile-file limits-fixture
     (lambda (work bytecode)
       (test-case "the Agentica writer matches the Racket writer on the large limit scenarios"
         (define result
           (parameterize ([current-directory root])
             (run-process vm-file #:timeout 1800 "--" (path->string bytecode) "slow")))
         (check-equal? (first result) 0 (third result))
         (define names (scenario-names "SLOW_SCENARIOS"))
         (check-equal? (length names) 4)
         (check-equal? (string-split (second result) "\n") (map racket-limits-line names)))))))
