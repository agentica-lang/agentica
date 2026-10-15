#lang racket

(require rackunit
         racket/runtime-path
         "frontend-modules-common.rkt"
         "frontend-corpus-common.rkt"
         "vm-diff-common.rkt")

(define-runtime-path root "..")
(define-runtime-path entry "../compiler/link.agc")

(define (with-bytecode proc) (call-with-bytecode compile-file entry proc))

; Read by the writer of the frozen comparisons (tests/frontend-modules-freeze.rkt).
(provide big-comment invalid-utf8-cases expected-position read-size mutated-fixtures site-programs deep-cases nested-chains)

; Runs compiler/link.agc once over the specs, each a (list env root-path) with the root path relative to the
; repository or absolute, and gives the text of each root by its path. mode is "" for the program text or
; "--ids" for the id ranges of the files.
(define (run-linker bytecode specs #:mode [mode ""])
  (define arguments
    (append (list (string-append "--stdlib=" (path->string stdlib-folder)))
            (if (string=? mode "") '() (list mode))
            (append* (for/list ([spec (in-list specs)])
                       (append (env-arguments (first spec)) (list (second spec)))))))
  (run-stage-sections bytecode arguments))

(define (golden input)
  (file->string (module-golden input)))

; Absolute: a fixture with links is copied outside the repository, and Racket names the root file of a
; failure by the path as given.
(define (input-path input)
  (path->string (simplify-path (module-input-root input))))

(define (agentica-matches-racket outputs specs)
  (for ([spec (in-list specs)])
    (define path (second spec))
    (check-equal? (hash-ref outputs path #f)
                  (string-append (parameterize ([current-directory root]) (link-text path #:env (first spec))) "\n")
                  path)))

(define (files-under directories)
  (agc-files-under directories #:keep? (lambda (file) (not (string-contains? (path->string file) "frontend/modules/")))))

; The files of a link as (name first next), from the `--ids` text.
(define (id-ranges text)
  (for/list ([line (in-list (string-split text "\n"))])
    (match-define (list _ name first next) (regexp-match #px"^module \"(.*)\" first=(\\d+) next=(\\d+)$" line))
    (list name (string->number first) (string->number next))))

(define (absolute-name folder name)
  (if (string-prefix? name "std/") name (path->string (simplify-path (build-path folder name)))))

; The ids of a link are one numbering: the first file starts at 0, each file starts where the one before it
; ended, and a file takes as many ids as it has nodes.
(define (check-id-ranges folder ranges label)
  (check-equal? (second (first ranges)) 0 label)
  (for ([earlier (in-list ranges)] [later (in-list (cdr ranges))])
    (check-equal? (second later) (third earlier) label))
  (define sizes (module-sizes (for/list ([range (in-list ranges)]) (absolute-name folder (first range)))))
  (for ([range (in-list ranges)] [size (in-list sizes)])
    (check-equal? (- (third range) (second range)) (cdr size) (format "~a ~a" label (first range)))))

(define (write-file path text)
  (make-parent-directory* path)
  (display-to-file text path #:exists 'truncate/replace)
  (path->string path))

(define (write-bytes-file path data)
  (make-parent-directory* path)
  (call-with-output-file path #:exists 'truncate/replace (lambda (out) (write-bytes data out)))
  (path->string path))

; compiler/source_file.agc reads 262144 bytes at a time. These cases put a character, or the start of an invalid
; sequence, across the edges of the reads.
(define read-size 262144)

(define (ascii count) (make-bytes count (char->integer #\a)))

; A comment that is a little over 1 MiB, with a 4-, 3-, 2- and 4-byte character each cut by a read edge.
(define (big-comment)
  (define (filler to-offset so-far) (ascii (- to-offset so-far)))
  (define pieces
    (list #"# " (filler (- read-size 1) 2) (string->bytes/utf-8 "\U1F600")
          (filler (- (* 2 read-size) 2) (+ read-size 3)) (string->bytes/utf-8 "\u65E5")
          (filler (- (* 3 read-size) 1) (+ (* 2 read-size) 1)) (string->bytes/utf-8 "\u00E9")
          (filler (- (* 4 read-size) 3) (+ (* 3 read-size) 1)) (string->bytes/utf-8 "\U1F600")
          (ascii 100) #"\n"))
  (apply bytes-append pieces))

; Cases of invalid UTF-8: (name valid-prefix bad-bytes suffix). The span must start at the first byte of the bad
; sequence, counted in the characters of the prefix, which Racket's own decoder counts here.
(define invalid-utf8-cases
  (let ([prefix (string->bytes/utf-8 "# \u00E9\u65E5\U1F600\ndef main() -> Void\n  puts(\"\u00E9")]
        [suffix #"\")\nend\n"])
    (list (list "a continuation byte alone" prefix #"\x80" suffix)
          (list "CRLF and a tab before the bad byte (CR and tab are one column, only LF starts a line)"
                #"# a\r\n\tx = \"\t" #"\xFF" #"\"\r\n")
          (list "a byte that never occurs" prefix #"\xFF" suffix)
          (list "a lead byte above F4" prefix #"\xF5" suffix)
          (list "an overlong two-byte form" prefix #"\xC0\x80" suffix)
          (list "an overlong three-byte form" prefix #"\xE0\x80\x80" suffix)
          (list "an overlong four-byte form" prefix #"\xF0\x80\x80\x80" suffix)
          (list "a surrogate" prefix #"\xED\xA0\x80" suffix)
          (list "a code point above U+10FFFF" prefix #"\xF4\x90\x80\x80" suffix)
          (list "a sequence cut short by an ASCII byte" prefix #"\xE2\x82" suffix)
          (list "a two-byte lead before a quote" prefix #"\xC3" suffix)
          (list "a truncated sequence at the end of the file" (bytes-append prefix #"\")\n") #"\xE2\x82" #"")
          (list "a lone lead byte at the end of the file" (bytes-append prefix #"\")\n") #"\xC3" #"")
          (list "a bad byte after the first read" (bytes-append #"# " (ascii (+ read-size 10)) #"\n# \xC3\xA9\n") #"\xFF" suffix)
          (list "a sequence whose first two bytes end the first read" (bytes-append #"# " (ascii (- read-size 4))) #"\xE2\x82" #"a\n")
          (list "a lead byte cut off by the first read" (bytes-append #"# " (ascii (- read-size 3))) #"\xE2" #"\x82a\n"))))

(define (expected-position prefix)
  (define text (bytes->string/utf-8 prefix))
  (define lines (string-split text "\n" #:trim? #f))
  (define column (add1 (string-length (last lines))))
  (format "~a:~a:~a-~a:~a:~a" (string-length text) (length lines) column (add1 (string-length text)) (length lines) (add1 column)))

(module+ test
  (define inputs (module-inputs))

  (test-case "the Racket printer matches its goldens"
    (for ([input (in-list inputs)])
      (check-equal? (string-append (link-text (module-input-root input) #:env (module-input-env input)) "\n")
                    (golden input)
                    (module-input-name input))))

  (when (vm-built? "frontend modules tests")
    (with-bytecode
      (lambda (work bytecode)
        (test-case "the files of a link share one numbering of node ids"
          (define names '("diamond" "empty-modules" "every-node" "pkg-environment-first" "canonical-identities" "bdd-steps"))
          (define chosen (filter (lambda (input) (member (module-input-name input) names)) inputs))
          (check-equal? (length chosen) (length names))
          (define ranges
            (run-linker bytecode (for/list ([input (in-list chosen)]) (list (module-input-env input) (input-path input))) #:mode "--ids"))
          (for ([input (in-list chosen)])
            (define folder (path->string (path-only (simplify-path (module-input-root input)))))
            (define found (id-ranges (hash-ref ranges (input-path input))))
            (check-true (> (length found) 1) (module-input-name input))
            (check-id-ranges (string-trim folder "/" #:left? #f) found (module-input-name input))))

        (test-case "the empty files of a link take ids too"
          (define input (findf (lambda (input) (equal? (module-input-name input) "empty-modules")) inputs))
          (define found
            (id-ranges (hash-ref (run-linker bytecode (list (list (module-input-env input) (input-path input))) #:mode "--ids")
                                 (input-path input))))
          (check-equal? (map first found) '("root.agc" "empty.agc" "imports_only.agc" "deep.agc" "after.agc")))

        (test-case "a root file that cannot be read is CHECK-IMPORT-IO at the start of the file"
          (define path (path->string (build-path work "missing.agc")))
          (define output (hash-ref (run-linker bytecode (list (list default-env path))) path))
          (check-regexp-match #rx"^ERROR CHECK-IMPORT-IO 0:1:1-0:1:1 " output)
          (check-regexp-match #rx"^ERROR CHECK-IMPORT-IO 0:1:1-0:1:1 " (link-text path)))

        ; Resolution allows "../", and the stored name of such a file keeps the .. part (35.4, "Source paths").
        (test-case "a file above the root folder is printed with .. parts, the same on both sides"
          (define root
            (write-file (build-path work "above" "app" "root.agc")
                        "import Shared from \"../shared/x\"\n\ndef main() -> Void\n  puts(Shared.name())\nend\n"))
          (write-file (build-path work "above" "shared" "x.agc") "export def name() -> String\n  return \"x\"\nend\n")
          (define output (hash-ref (run-linker bytecode (list (list default-env root))) root))
          (check-regexp-match #rx"\n  module \"../shared/x.agc\"\n" output)
          (check-equal? output (string-append (link-text root #:env default-env) "\n")))

        ; The stored name comes from the canonical file, so a link in the way of the entry changes nothing.
        (test-case "an entry reached through a symbolic link to its folder is named from the real folder, on both sides"
          (define real (build-path work "linked" "real" "app"))
          (write-file (build-path real "root.agc")
                      "import Shared from \"../shared/x\"\n\ndef main() -> Void\n  puts(Shared.name())\nend\n")
          (write-file (build-path work "linked" "real" "shared" "x.agc") "export def name() -> String\n  return \"x\"\nend\n")
          (make-file-or-directory-link (build-path "real" "app") (build-path work "linked" "linkapp"))
          (define root (path->string (build-path work "linked" "linkapp" "root.agc")))
          (define output (hash-ref (run-linker bytecode (list (list default-env root))) root))
          (check-regexp-match #rx"\n  module \"root.agc\"\n" output)
          (check-regexp-match #rx"\n  module \"../shared/x.agc\"\n" output)
          (check-equal? output (string-append (link-text root #:env default-env) "\n")))

        (test-case "invalid UTF-8 in the root file or in an import is LEX-INVALID-UTF8 at its first bad byte, the same on both sides"
          (define specs
            (append*
             (for/list ([entry (in-list invalid-utf8-cases)] [n (in-naturals)])
               (match-define (list name prefix bad suffix) entry)
               (define content (bytes-append prefix bad suffix))
               (define as-root (write-bytes-file (build-path work "utf8" (format "root-~a" n) "root.agc") content))
               (define as-import
                 (begin
                   (write-bytes-file (build-path work "utf8" (format "import-~a" n) "bad.agc") content)
                   (write-file (build-path work "utf8" (format "import-~a" n) "root.agc")
                               "import Bad from \"./bad\"\n\ndef main() -> Void\nend\n")))
               (list (list default-env as-root) (list default-env as-import)))))
          (define outputs (run-linker bytecode specs))
          (for ([entry (in-list invalid-utf8-cases)] [n (in-naturals)])
            (match-define (list name prefix _ _) entry)
            (define span (expected-position prefix))
            (for ([label (in-list '("root" "import"))] [spec (in-list (list-tail specs (* 2 n)))])
              (define path (second spec))
              (define output (hash-ref outputs path))
              (check-equal? output (string-append (link-text path) "\n") (format "~a, ~a" name label))
              (check-regexp-match (regexp (string-append "^ERROR LEX-INVALID-UTF8 " span " \"source file is not valid UTF-8\" ")) output)
              (check-regexp-match (if (equal? label "root") #rx"file=\"root.agc\"\n?$" #rx"file=\"bad.agc\"\n?$") output))))

        (test-case "a source file that cannot be read as an import is CHECK-IMPORT-IO, \"cannot read import\", on both sides"
          (define root (write-file (build-path work "unreadable" "root.agc") "import Bad from \"./bad\"\n\ndef main() -> Void\nend\n"))
          (make-directory* (build-path work "unreadable" "bad.agc"))
          (define output (hash-ref (run-linker bytecode (list (list default-env root))) root))
          (check-regexp-match #rx"^ERROR CHECK-IMPORT-IO [^ ]+ \"cannot read import\"" output)
          (check-equal? output (string-append (link-text root) "\n")))

        (test-case "a valid source file over 1 MiB links, as the root and as an import, with characters cut by the reads"
          (define comment (big-comment))
          (check-true (> (bytes-length comment) 1048576))
          (define program #"def main() -> Void\n  puts(\"big\")\nend\n")
          (define as-root (write-bytes-file (build-path work "big" "alone" "root.agc") (bytes-append comment program)))
          (write-bytes-file (build-path work "big" "imported" "big.agc")
                            (bytes-append comment #"export def one() -> Int\n  return 1\nend\n"))
          (define as-import
            (write-file (build-path work "big" "imported" "root.agc")
                        "import Big from \"./big\"\n\ndef main() -> Void\n  puts(Big.one().to_s)\nend\n"))
          (define specs (list (list default-env as-root) (list default-env as-import)))
          (define outputs (run-linker bytecode specs))
          (for ([spec (in-list specs)])
            (check-false (regexp-match? #rx"^ERROR" (hash-ref outputs (second spec))) (second spec)))
          (agentica-matches-racket outputs specs))

        ; Racket's find-system-path ignores a replaced environment, so the HOME-based user root cannot be
        ; compared with Racket in a hermetic way: the Agentica linker is given --home and no usable
        ; XDG_DATA_HOME (relative values are ignored) and the library is found under ~/.local/share/agentica/lib.
        (test-case "the user library root falls back to HOME/.local/share/agentica/lib"
          (define home (build-path work "home"))
          (write-file (build-path home ".local" "share" "agentica" "lib" "homelib.agc") "export def answer() -> Int\n  return 42\nend\n")
          (define root
            (write-file (build-path work "home-root" "root.agc")
                        "import Homelib from \"pkg/homelib\"\n\ndef main() -> Void\n  puts(Homelib.answer().to_s)\nend\n"))
          (define env (hash "AGENTICA_PATH" "" "XDG_DATA_HOME" "relative/data" "HOME" (path->string home)))
          (define output (hash-ref (run-linker bytecode (list (list env root))) root))
          (check-false (regexp-match? #rx"^ERROR" output) output)
          (check-regexp-match #rx"module \"[^\"]*homelib.agc\"" output))))))

(module+ slow
  (when (vm-built? "frontend modules tests")
    (with-bytecode
      (lambda (work bytecode)
        (define live-paths (files-under '("examples" "stdlib" "tests/fixtures")))
        (test-case "while Racket exists: the Agentica linker matches the Racket linker on examples/, stdlib/ and tests/fixtures/"
          (define specs (for/list ([path (in-list live-paths)]) (list default-env path)))
          (agentica-matches-racket (run-linker bytecode specs) specs))

        (test-case "while Racket exists: the Agentica linker matches the Racket linker on the programs of the site"
          (define specs
            (for/list ([block (in-list (site-programs))] [n (in-naturals)])
              (list default-env (write-file (build-path work "site" (format "block-~a.agc" n)) block))))
          (check-true (> (length specs) 100))
          (agentica-matches-racket (run-linker bytecode specs) specs))

        (test-case "while Racket exists: the Agentica linker matches the Racket linker on 300 mutated fixtures"
          (define specs
            (for/list ([dir (in-list (mutated-fixtures work 300))])
              (list default-env (path->string (build-path dir "root.agc")))))
          (define outputs (run-linker bytecode specs))
          (agentica-matches-racket outputs specs)
          (define errors
            (for/sum ([spec (in-list specs)]) (if (regexp-match? #rx"^ERROR" (hash-ref outputs (second spec))) 1 0)))
          (check-true (< 30 errors 290) (format "~a of 300 mutated fixtures are errors" errors)))

        (test-case "a chain of 3000 files and a file importing 2000 files link, with one numbering of ids"
          (define chain (build-path work "chain"))
          (for ([n (in-range 3000)])
            (write-file (build-path chain (format "m~a.agc" n))
                        (if (< n 2999)
                            (format "import Next from \"m~a\"\nexport def f~a() -> Int\n  return Next.f~a()\nend\n\n" (add1 n) n (add1 n))
                            (format "export def f~a() -> Int\n  return 1\nend\n\n" n))))
          (define wide (build-path work "wide"))
          (for ([n (in-range 2000)])
            (write-file (build-path wide (format "w~a.agc" n)) (format "export def g~a() -> Int\n  return ~a\nend\n\n" n n)))
          (write-file (build-path wide "root.agc")
                      (string-append (string-append* (for/list ([n (in-range 2000)]) (format "import W~a from \"w~a\"\n" n n)))
                                     "def main() -> Void\n  puts(W0.g0())\nend\n\n"))
          (define specs (list (list default-env (path->string (build-path chain "m0.agc")))
                              (list default-env (path->string (build-path wide "root.agc")))))
          (define outputs (run-linker bytecode specs))
          (agentica-matches-racket outputs specs)
          (define ranges (run-linker bytecode specs #:mode "--ids"))
          (for ([spec (in-list specs)])
            (check-id-ranges (path->string (path-only (second spec))) (id-ranges (hash-ref ranges (second spec))) (second spec))))

        (test-case "a long import cycle and a failure at the end of a long chain give the same diagnostic"
          (define cycle (build-path work "cycle"))
          (for ([n (in-range 1500)])
            (write-file (build-path cycle (format "c~a.agc" n))
                        (format "import Next from \"c~a\"\n" (modulo (add1 n) 1500))))
          (define broken (build-path work "broken"))
          (for ([n (in-range 1500)])
            (write-file (build-path broken (format "b~a.agc" n))
                        (if (< n 1499)
                            (format "import Next from \"b~a\"\nexport def f() -> Int\n  return Next.f()\nend\n\n" (add1 n))
                            "export def f() -> Int\n  return Nope.Thing\nend\n\n")))
          (define specs (list (list default-env (path->string (build-path cycle "c0.agc")))
                              (list default-env (path->string (build-path broken "b0.agc")))))
          (define outputs (run-linker bytecode specs))
          (agentica-matches-racket outputs specs)
          (check-regexp-match #rx"^ERROR CHECK-IMPORT-CYCLE" (hash-ref outputs (second (first specs)))))

        (test-case "deep trees: the linker rewrites chains, nested chains, calls and types as deep as the parser lets them be"
          (define cases (deep-cases))
          (define specs
            (for/list ([entry (in-list cases)])
              (list default-env (write-file (build-path work "deep" (format "~a.agc" (car entry))) (cdr entry)))))
          (define outputs (run-linker bytecode specs #:mode "--ids"))
          (for ([spec (in-list specs)] [entry (in-list cases)])
            (define output (hash-ref outputs (second spec)))
            (define racket (link-text (second spec)))
            (if (regexp-match? #rx"^ERROR" racket)
                (check-equal? output (string-append racket "\n") (car entry))
                (check-id-ranges (path->string (path-only (second spec))) (id-ranges output) (car entry)))))

        (test-case "a file of 2000 declarations links in linear time"
          (define path
            (write-file (build-path work "flat.agc")
                        (string-append* (for/list ([n (in-range 2000)])
                                          (format "def f~a(a: Int) -> Int\n  return a + ~a\nend\n\n" n n)))))
          (define started (current-inexact-milliseconds))
          (define outputs (run-linker bytecode (list (list default-env path))))
          (check-true (< (- (current-inexact-milliseconds) started) 60000))
          (agentica-matches-racket outputs (list (list default-env path))))))))

; Copies of count fixture folders, each with one or two of its files mutated (a cut, a deletion, a snippet from
; the list of risky ones, a renamed alias or a changed declaration keyword), under dir.
(define risky
  '("import X from \"x\"\n" "export " "std/queue" "pkg/" "../" "Nope." "HttpWire." "Lib." "A." "M." ".Some(" "(a: 1)" "end\n"
    "\n\n" "def " "struct " "enum " "\"" "ok(" "Await." "LogLevel." "Result." " as " "import " "\\" ":" "//"))

(define (mutate text)
  (define size (string-length text))
  (define at (if (zero? size) 0 (random (add1 size))))
  (define (pick items) (list-ref items (random (length items))))
  (case (random 5)
    [(0) (substring text 0 at)]
    [(1) (if (< at size) (string-append (substring text 0 at) (substring text (min size (+ at 1 (random 5))))) text)]
    [(2) (string-append (substring text 0 at) (pick risky) (substring text at))]
    [(3) (string-replace text (pick '("Lib" "A" "M" "Util" "Q" "Next")) (pick '("Lib" "A" "Header" "Zed" "M" "Util")) #:all? #f)]
    [else (string-replace text (pick '("export def" "def " "struct " "import ")) (pick '("export struct" "def " "enum " "import ")) #:all? #f)]))

(define (mutated-fixtures dir count)
  (parameterize ([current-pseudo-random-generator (make-pseudo-random-generator)])
    (random-seed 254)
    (define sources (map module-input-dir (module-inputs)))
    (for/list ([n (in-range count)])
      (define target (build-path dir "mutated" (format "case-~a" n)))
      (make-parent-directory* target)
      (copy-directory/files (list-ref sources (random (length sources))) target #:preserve-links? #t)
      (define files
        (for/list ([file (in-directory target)]
                   #:when (and (file-exists? file) (not (link-exists? file)) (path-has-extension? file #".agc")))
          file))
      (for ([_ (in-range (add1 (random 2)))] #:when (pair? files))
        (define file (list-ref files (random (length files))))
        (display-to-file (mutate (file->string file)) file #:exists 'truncate/replace))
      target)))

; The programs in the code blocks of the site's pages.
(define (site-programs)
  (append*
   (for/list ([page (in-directory (build-path root "site" "content"))] #:when (path-has-extension? page #".md"))
     (let loop ([lines (file->lines page)] [open #f] [found '()])
       (cond
         [(null? lines) (reverse found)]
         [(and (not open) (regexp-match? #px"^```(agentica|agc)\\b" (car lines))) (loop (cdr lines) '() found)]
         [(and open (regexp-match? #px"^```\\s*$" (car lines)))
          (loop (cdr lines) #f (cons (string-append (string-join (reverse open) "\n") "\n") found))]
         [open (loop (cdr lines) (cons (car lines) open) found)]
         [else (loop (cdr lines) open found)])))))

(define (repeat text count) (string-append* (make-list count text)))

(define (function-body body) (string-append "def main() -> Void\n" body "end\n\n"))

; k chains of l links, each inside the right operand of the first link of the next: the tree is k * l levels
; deep (7,200 for 8 times 900), where the parser only counts about 2 levels for each chain.
(define (nested-chains k l)
  (for/fold ([text "x"]) ([_ (in-range k)])
    (string-append "x + (" text ")" (repeat " + x" l))))

; Trees as deep as the parser allows. Each ends in a name that the linker refuses (Nope.Thing), so that the
; diagnostic shows the walk reached the deepest node, and the legal variants are checked by their ids.
(define (deep-cases)
  (define (bad-then text) (function-body (string-append "  y = " text "\n")))
  (list
   (cons "chain-ok" (bad-then (string-append "x" (repeat " + x" 998))))
   (cons "chain-bad" (bad-then (string-append "Nope.Thing" (repeat " + x" 998))))
   (cons "method-bad" (bad-then (string-append "Nope.Thing" (repeat ".f(1)" 997))))
   (cons "nested-chains-ok" (bad-then (string-append "x + (x + (x + (x" (repeat " + x" 400) ")))")))
   (cons "nested-chains-bad" (bad-then (string-append "x + (x + (x + (Nope.Thing" (repeat " + x" 400) ")))")))
   (cons "nested-chains-deep-ok" (bad-then (nested-chains 8 900)))
   (cons "nested-chains-limit-ok" (bad-then (nested-chains 11 900)))
   (cons "nested-chains-deep-bad" (bad-then (string-append "Nope.Thing + (" (nested-chains 7 900) ")" (repeat " + x" 900))))
   (cons "calls-bad" (bad-then (string-append (repeat "f(" 900) "Nope.Thing" (repeat ")" 900))))
   (cons "lists-bad" (bad-then (string-append (repeat "[" 990) "Nope.Thing" (repeat "]" 990))))
   (cons "types-bad" (string-append "def f(a: " (repeat "List[" 900) "Nope.Thing" (repeat "]" 900) ") -> Void\nend\n\n"))
   (cons "ifs-bad" (function-body (string-append (repeat "  if x\n" 400) "  y = Nope.Thing\n" (repeat "  end\n" 400))))))
