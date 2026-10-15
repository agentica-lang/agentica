#lang racket

(require rackunit
         racket/runtime-path
         "frontend-check-common.rkt"
         (only-in "frontend-lexer-common.rkt" call-with-bytecode)
         "vm-diff-common.rkt"
         "../src/builtins.rkt"
         "../tools/gen-builtins-data.rkt"
         "../tools/gen-check-tables.rkt")

(define-runtime-path root "..")
(define-runtime-path entry "../compiler/check.agc")
(define-runtime-path tables "../compiler/check_tables.agc")
(define-runtime-path stdlib-folder "../stdlib")
(define-runtime-path checker-source "../src/checker.rkt")
(define-runtime-path checker-cases "checker-test.rkt")

(define (with-bytecode proc) (call-with-bytecode compile-file entry proc))

; Runs compiler/check.agc once over the paths and gives the text of each by its path.
(define (run-checker bytecode paths #:timeout [timeout 600])
  (define result
    (parameterize ([current-directory root])
      (apply run-process vm-file #:timeout timeout "--" (path->string bytecode)
             (string-append "--stdlib=" (path->string stdlib-folder))
             (map (lambda (path) (if (path? path) (path->string path) path)) paths))))
  (check-equal? (first result) 0 (third result))
  (check-equal? (third result) "")
  (for/hash ([piece (in-list (cdr (regexp-split #rx"(?m:^== )" (second result))))])
    (define newline-at (let loop ([at 0]) (if (char=? (string-ref piece at) #\newline) at (loop (add1 at)))))
    (values (substring piece 0 newline-at) (substring piece (add1 newline-at)))))

(define (golden input) (file->string (check-golden input)))

(define (input-path input) (path->string (simplify-path (check-input-root input))))

(define (agentica-matches-racket outputs paths)
  (for ([path (in-list paths)])
    (check-equal? (hash-ref outputs path #f) (string-append (check-text path) "\n") path)))

(define (write-file path text)
  (make-parent-directory* path)
  (display-to-file text path #:exists 'truncate/replace)
  (path->string path))

; The codes the Racket checker has and no program can reach: CHECK-INTERNAL guards an impossible node,
; CHECK-MODULE-CONTEXT a program that still has imports (the linker removes them) and CHECK-BLOCK-TYPE a
; block with no expected type (a block is only parsed after a call, whose parameter gives the type).
(define unreachable-codes '("CHECK-INTERNAL" "CHECK-MODULE-CONTEXT" "CHECK-BLOCK-TYPE"))

(module+ test
  (define inputs (check-inputs))

  (test-case "compiler/check_tables.agc is the method tables of src/checker.rkt"
    (unless (equal? (file->string tables) (check-tables-source))
      (fail "compiler/check_tables.agc is out of date: run racket tools/gen-check-tables.rkt")))

  (test-case "every fixture has a golden and no golden is left over"
    (define expected (sort (map (lambda (input) (path->string (file-name-from-path (check-golden input)))) inputs) string<?))
    (define found
      (sort (for/list ([file (in-list (directory-list (path-only (check-golden (car inputs)))))]
                       #:when (path-has-extension? file #".checked"))
              (path->string file))
            string<?))
    (check-equal? found expected))

  (test-case "the fixtures end in every CHECK- diagnostic the checker can give"
    (define codes (remove-duplicates (regexp-match* #rx"CHECK-[A-Z-]+" (file->string checker-source))))
    (define seen (string-append* (map golden inputs)))
    (for ([code (in-list codes)] #:unless (member code unreachable-codes))
      (check-true (string-contains? seen (string-append "ERROR " code " ")) code)))

  (test-case "the fixtures check a call of a builtin of every rule of the builtin table"
    (define seen (string-append* (map golden inputs)))
    (define used
      (append (map cadr (regexp-match* #rx"name=\"([^\"]+)\" piped" seen #:match-select values))
              (map cadr (regexp-match* #rx"resolved=call\\(\"([^\"]+)\"" seen #:match-select values))))
    (define covered (remove-duplicates (for/list ([name (in-list used)] #:when (hash-ref builtins name #f))
                                         (rule-variant (builtin-rule (hash-ref builtins name))))))
    (define all (remove-duplicates (for/list ([entry (in-hash-values builtins)]) (rule-variant (builtin-rule entry)))))
    (check-equal? (sort (remove* covered all) string<?) '()))

  (test-case "the Racket printer matches its goldens"
    (for ([input (in-list inputs)])
      (check-equal? (string-append (check-text (check-input-root input)) "\n") (golden input) (check-input-name input))))

  (when (vm-built? "frontend check tests")
    (with-bytecode
      (lambda (work bytecode)
        (test-case "the Agentica checker matches the goldens on the VM: types, resolutions and diagnostics"
          (define outputs (run-checker bytecode (map input-path inputs)))
          (for ([input (in-list inputs)])
            (check-equal? (hash-ref outputs (input-path input) #f) (golden input) (check-input-name input))))))))

; The programs of the cases of tests/checker-test.rkt, in the order they are checked there. The cases run when
; the test submodule is first instantiated, so the programs are collected once and kept: a second call would
; find the module instantiated and collect nothing.
(define collected-programs #f)

(define (checker-case-programs)
  (unless collected-programs (set! collected-programs (collect-checker-case-programs)))
  collected-programs)

(define (collect-checker-case-programs)
  (define found '())
  (define seen (make-hash))
  (define sink (dynamic-require checker-cases 'current-text-sink))
  (parameterize ([sink (lambda (text)
                         (unless (hash-ref seen text #f)
                           (hash-set! seen text #t)
                           (set! found (cons text found))))])
    (dynamic-require `(submod ,checker-cases test) #f))
  (reverse found))

(define (agc-files-in directory)
  (for/list ([file (in-list (directory-list (build-path root directory) #:build? #t))]
             #:when (path-has-extension? file #".agc"))
    (path->string (simplify-path file))))

(define token-pattern #px"[A-Za-z_][A-Za-z_0-9?!]*|[0-9]+(?:[.][0-9]+)?|\"[^\"\n]*\"|==|!=|<=|>=|[-+*/%<>]")

(define extra-tokens
  '("Int" "String" "Float" "Bool" "Nil" "Json" "Range" "size" "length" "to_s" "push" "map" "keys" "get" "put" "nil" "true"
    "false" "0" "1" "2.5" "\"s\"" "+" "-" "==" "<" "and" "or" "x" "xs" "unwrap!" "Void" "upcase" "first"))

; The program with one to three of its tokens replaced by another token of the program or of a list of risky
; ones: most mutants still parse, so they reach the checker and break one of its rules.
(define (mutate-tokens text)
  (for/fold ([text text]) ([_ (in-range (add1 (random 3)))])
    (define spans (regexp-match-positions* token-pattern text))
    (cond
      [(null? spans) text]
      [else
       (define pool (append (map (lambda (span) (substring text (car span) (cdr span))) spans) extra-tokens))
       (define span (list-ref spans (random (length spans))))
       (string-append (substring text 0 (car span)) (list-ref pool (random (length pool))) (substring text (cdr span)))])))

(define (mutated-programs programs count)
  (when (null? programs) (error 'mutated-programs "no programs to mutate"))
  (parameterize ([current-pseudo-random-generator (make-pseudo-random-generator)])
    (random-seed 258)
    (for/list ([_ (in-range count)])
      (mutate-tokens (list-ref programs (random (length programs)))))))

(define (repeat text count) (string-append* (make-list count text)))

; k chains of l links, each inside the right operand of the first link of the next: the tree is k * l levels
; deep, where the parser only counts about 2 levels for each chain.
(define (nested-chains k l)
  (for/fold ([text "x"]) ([_ (in-range k)])
    (string-append "x + (" text ")" (repeat " + x" l))))

(define (function-body body)
  (string-append "def f(a: Int) -> Int\n  return a\nend\n\ndef main() -> Void\n  x = 1\n" body "end\n\n"))

; Trees around the nesting limit: the Racket and the Agentica checker accept the same depth and give
; CHECK-TOO-DEEP at the same node. The limit is 1000 levels of expressions and statements (check_state.agc).
(define (deep-cases)
  (define (bind text) (function-body (string-append "  y = " text "\n  puts(y)\n")))
  (list
   (cons "chain-900" (bind (string-append "x" (repeat " + x" 900))))
   (cons "chain-997" (bind (string-append "x" (repeat " + x" 997))))
   (cons "chain-998" (bind (string-append "x" (repeat " + x" 998))))
   (cons "nested-chains" (bind (nested-chains 8 900)))
   (cons "calls-900" (bind (string-append (repeat "f(" 900) "x" (repeat ")" 900))))
   (cons "calls-998" (bind (string-append (repeat "f(" 998) "x" (repeat ")" 998))))
   (cons "lists-990" (bind (string-append (repeat "[" 990) "x" (repeat "]" 990))))
   (cons "negations" (bind (string-append (repeat "-" 997) "x")))
   (cons "ifs" (function-body (string-append (repeat "  if x == 1\n" 450) "  puts(x)\n" (repeat "  end\n" 450))))
   (cons "ifs-and-chains"
         (function-body (string-append (repeat "  if x == 1\n" 300) "  y = " (nested-chains 2 500) "\n" (repeat "  end\n" 300))))
   (cons "chain-999" (bind (string-append "x" (repeat " + x" 999))))))

; count functions that use structs, enums, lists, maps, case, blocks and interpolation.
(define (generated-program count)
  (string-append
   "struct Item\n  id: Int\n  name: String\n  score: Float\nend\n\nenum Shape\n  Circle(Float)\n  Rect(Float, Float)\nend\n\n"
   (string-append*
    (for/list ([n (in-range count)])
      (format #<<END
def f~a(xs: List[Int], label: String) -> Int
  total = 0
  items: List[Item] = []
  for x in xs
    if x % 2 == 0 and x > ~a
      total += x * ~a
    elsif x < 0
      total -= x
    else
      items = items.push(Item(id: x, name: "~a-" + label, score: 1.5))
    end
  end
  shape = Shape.Rect(1.0, 2.0)
  area = 0.0
  case shape
    Shape.Circle(r) -> area = r * r
    Shape.Rect(w, h) -> area = w * h
  end
  names = items.map do |it: Item| it.name.upcase end
  m: Map[String, Int] = {"a": 1, "b": ~a}
  total += names.size + m.size
  puts("f~a #{total} #{area} #{names.join(",")}")
  return total
end


END
              n (modulo n 7) (add1 (modulo n 5)) n n n)))
   "def main() -> Void\n  puts(f0([1, 2, 3], \"x\"))\nend\n"))

(module+ slow
  (when (vm-built? "frontend check tests")
    (with-bytecode
      (lambda (work bytecode)
        (test-case "while Racket exists: the Agentica checker matches the Racket checker on the programs of tests/checker-test.rkt"
          (define programs (checker-case-programs))
          (check-true (> (length programs) 400))
          (define paths
            (for/list ([text (in-list programs)] [n (in-naturals)])
              (write-file (build-path work "cases" (format "c~a.agc" n)) text)))
          (agentica-matches-racket (run-checker bytecode paths) paths))

        (test-case "while Racket exists: the Agentica checker matches the Racket checker on 1,500 mutated programs"
          (define paths
            (for/list ([text (in-list (mutated-programs (checker-case-programs) 1500))] [n (in-naturals)])
              (write-file (build-path work "mutated" (format "m~a.agc" n)) text)))
          (define outputs (run-checker bytecode paths))
          (agentica-matches-racket outputs paths)
          (define checked
            (for/sum ([path (in-list paths)]) (if (regexp-match? #rx"^ERROR (PARSE|LEX)-" (hash-ref outputs path)) 0 1)))
          (check-true (> checked 150) (format "~a of 1500 mutants reach the checker" checked)))

        (test-case "while Racket exists: the Agentica checker matches the Racket checker on examples/ and tests/fixtures/vm/"
          (define paths (append (agc-files-in "examples") (agc-files-in "tests/fixtures/vm")))
          (check-true (> (length paths) 200))
          (agentica-matches-racket (run-checker bytecode paths) paths))

        (test-case "while Racket exists: the Agentica checker matches the Racket checker on every std/ module and the compiler"
          (define wrappers
            (for/list ([file (in-directory stdlib-folder)] #:when (path-has-extension? file #".agc"))
              (define name (path->string (path-replace-extension (find-relative-path (simplify-path stdlib-folder) (simplify-path file)) #"")))
              (write-file (build-path work "std" (string-append (string-replace name "/" "_") ".agc"))
                          (format "import \"std/~a\" as Module\n\ndef main() -> Void\nend\n" name))))
          (define paths (append wrappers (agc-files-in "compiler")))
          (agentica-matches-racket (run-checker bytecode paths) paths))

        (test-case "while Racket exists: trees around the nesting limit give the same types or the same CHECK-TOO-DEEP"
          (define cases (deep-cases))
          (define paths
            (for/list ([entry (in-list cases)])
              (write-file (build-path work "deep" (format "~a.agc" (car entry))) (cdr entry))))
          (define outputs (run-checker bytecode paths))
          (agentica-matches-racket outputs paths)
          (define (output-of name) (hash-ref outputs (path->string (build-path work "deep" (format "~a.agc" name)))))
          (check-regexp-match #rx"^ERROR CHECK-TOO-DEEP " (output-of "nested-chains"))
          (check-regexp-match #rx"^ERROR CHECK-TOO-DEEP " (output-of "ifs-and-chains"))
          (check-regexp-match #rx"^ERROR PARSE-TOO-DEEP " (output-of "chain-999"))
          (check-false (regexp-match? #rx"^ERROR" (output-of "chain-900"))))

        (test-case "a generated program of 1,000 functions (630,000 characters) checks in the same time class as the link"
          (define path (write-file (build-path work "generated.agc") (generated-program 1000)))
          (define started (current-inexact-milliseconds))
          (define outputs (run-checker bytecode (list path)))
          (check-true (< (- (current-inexact-milliseconds) started) 120000))
          (agentica-matches-racket outputs (list path)))))))
