#lang racket

; The Agentica lowering (compiler/lower.agc) against the Racket lowering (src/lower.rkt): the text forms of
; tests/frontend-lower-common.rkt on the golden fixtures, and, in the slow tier, on the whole corpus.

(require rackunit
         racket/runtime-path
         "frontend-lower-common.rkt"
         (only-in "frontend-lexer-common.rkt" call-with-bytecode)
         "vm-diff-common.rkt"
         "../src/bytecode.rkt"
         "../src/lower.rkt")

(define-runtime-path root "..")
(define-runtime-path entry "../compiler/lower.agc")
(define-runtime-path tables "../compiler/lower_tables.agc")
(define-runtime-path stdlib-folder "../stdlib")
(define-runtime-path checker-cases "checker-test.rkt")

(define (with-bytecode proc) (call-with-bytecode compile-file entry proc))

; Runs compiler/lower.agc once over the paths and gives the text of each by its path. flags come first (for
; example --burn=N).
(define (run-lowering bytecode paths #:flags [flags '()] #:timeout [timeout 600])
  (define result
    (parameterize ([current-directory root])
      (apply run-process vm-file #:timeout timeout "--" (path->string bytecode)
             (string-append "--stdlib=" (path->string stdlib-folder))
             (append flags (map (lambda (path) (if (path? path) (path->string path) path)) paths)))))
  (values (first result) (second result) (third result)))

(define (texts-by-path bytecode paths #:flags [flags '()])
  (define-values (status out err) (run-lowering bytecode paths #:flags flags))
  (check-equal? status 0 err)
  (check-equal? err "")
  (parse-texts out))

(define (parse-texts out)
  (for/hash ([piece (in-list (cdr (regexp-split #rx"(?m:^== )" out)))])
    (define newline-at (let loop ([at 0]) (if (char=? (string-ref piece at) #\newline) at (loop (add1 at)))))
    (values (substring piece 0 newline-at) (substring piece (add1 newline-at)))))

(define (golden input) (file->string (lower-golden input)))

(define (input-path input) (path->string (simplify-path (lower-input-root input))))

(define (agentica-matches-racket outputs paths)
  (for ([path (in-list paths)])
    (check-equal? (hash-ref outputs path #f) (string-append (lower-text path) "\n") path)))

(define (write-file path text)
  (make-parent-directory* path)
  (display-to-file text path #:exists 'truncate/replace)
  (path->string path))

(define (agc-files-in directory)
  (for/list ([file (in-list (directory-list (build-path root directory) #:build? #t))]
             #:when (path-has-extension? file #".agc"))
    (path->string (simplify-path file))))

; The names of the VM_BUILTINS constant of compiler/lower_tables.agc: the strings between its brackets.
(define (agentica-vm-builtins)
  (define text (file->string tables))
  (define at (car (regexp-match-positions #rx"VM_BUILTINS = Set.new\\(\\[" text)))
  (define end (car (regexp-match-positions #rx"\n\\]\\)" text (cdr at))))
  (map cadr (regexp-match* #rx"\"([^\"]+)\"" (substring text (cdr at) (car end)) #:match-select values)))

(module+ test
  (define inputs (lower-inputs))

  (test-case "VM_BUILTINS of compiler/lower_tables.agc is vm-builtins of src/lower.rkt"
    (check-equal? (sort (agentica-vm-builtins) string<?) (sort vm-builtins string<?)))

  (test-case "every fixture has a golden and no golden is left over"
    (define expected (sort (map (lambda (input) (path->string (file-name-from-path (lower-golden input)))) inputs) string<?))
    (define found
      (sort (for/list ([file (in-list (directory-list (path-only (lower-golden (car inputs)))))]
                       #:when (path-has-extension? file #".ir"))
              (path->string file))
            string<?))
    (check-equal? found expected))

  (test-case "the fixtures lower an instruction of every opcode of the bytecode"
    (define seen (string-append* (map golden inputs)))
    (for ([op (in-list opcodes)])
      (check-true (regexp-match? (regexp (format "(?m:^    ~a( |$))" op)) seen) (symbol->string op))))

  (test-case "the fixtures cover chunked literals, decodable structs, constants and the start function"
    (define seen (string-append* (map golden inputs)))
    (for ([needle (in-list '("\"List.concat\"" "\"Map.put\"" " types=[" "\"<start>\"" "\"Task.await_result\""
                             "tail-call" "struct-with" "global-set" "call-value" "range-bounds"))])
      (check-true (string-contains? seen needle) needle)))

  (test-case "the Racket printer matches its goldens"
    (for ([input (in-list inputs)])
      (check-equal? (string-append (lower-text (lower-input-root input)) "\n") (golden input) (lower-input-name input))))

  (when (vm-built? "frontend lower tests")
    (with-bytecode
      (lambda (work bytecode)
        (test-case "the Agentica lowering matches the goldens on the VM"
          (define outputs (texts-by-path bytecode (map input-path inputs)))
          (for ([input (in-list inputs)])
            (check-equal? (hash-ref outputs (input-path input) #f) (golden input) (lower-input-name input))))

        (test-case "while Racket exists: the Agentica lowering matches the Racket lowering on examples/"
          (define paths (agc-files-in "examples"))
          (check-true (> (length paths) 20))
          (agentica-matches-racket (texts-by-path bytecode paths) paths))))))

; The programs of the cases of tests/checker-test.rkt, collected as the checker test does.
(define collected-programs #f)

(define (checker-case-programs)
  (unless collected-programs
    (define found '())
    (define seen (make-hash))
    (define sink (dynamic-require checker-cases 'current-text-sink))
    (parameterize ([sink (lambda (text)
                           (unless (hash-ref seen text #f)
                             (hash-set! seen text #t)
                             (set! found (cons text found))))])
      (dynamic-require `(submod ,checker-cases test) #f))
    (set! collected-programs (reverse found)))
  collected-programs)

(define (repeat text count) (string-append* (make-list count text)))

(define (function-body body)
  (string-append "def f(a: Int) -> Int\n  return a\nend\n\ndef main() -> Void\n  x = 1\n" body "end\n\n"))

; Trees at the nesting limit of the checker (1,000 levels): lowering recurses on the tree, so these are the
; deepest inputs it can see. Each name is a shape; the number is how deep it is nested.
(define (deep-cases)
  (define (bind text) (function-body (string-append "  y = " text "\n  puts(y)\n")))
  (list
   (cons "chain-997" (bind (string-append "x" (repeat " + x" 997))))
   (cons "calls-998" (bind (string-append (repeat "f(" 998) "x" (repeat ")" 998))))
   (cons "lists-990" (bind (string-append (repeat "[" 990) "x" (repeat "]" 990))))
   (cons "negations" (bind (string-append (repeat "-" 997) "x")))
   (cons "parentheses" (bind (string-append (repeat "(x + " 490) "x" (repeat ")" 490))))
   (cons "interpolations" (bind (string-append (repeat "\"#{" 990) "x" (repeat "}\"" 990))))
   (cons "ifs-990" (function-body (string-append (repeat "  if x == 1\n" 990) "  puts(x)\n" (repeat "  end\n" 990))))
   (cons "whiles-990" (function-body (string-append (repeat "  while x < 0\n" 990) "  puts(x)\n" (repeat "  end\n" 990))))
   (cons "blocks-200"
         (function-body
          (string-append "  xs = [1]\n  y = "
                         (string-append* (for/list ([i (in-range 200)]) (format "xs.map do |v~a| " i)))
                         "v199" (repeat " end" 200) "\n")))))

; count functions that use structs, enums, lists, maps, case, blocks, interpolation and a constant.
(define (generated-program count)
  (string-append
   "LABELS = [\"a\", \"b\"]\nSCALE = 3\n\n"
   "struct Item\n  id: Int\n  name: String\n  score: Float\nend\n\nenum Shape\n  Circle(Float)\n  Rect(Float, Float)\nend\n\n"
   (string-append*
    (for/list ([n (in-range count)])
      (format #<<END
def f~a(xs: List[Int], label: String) -> Int
  total = 0
  items: List[Item] = []
  for x in xs
    if x % 2 == 0 and x > ~a
      total += x * SCALE
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
  total += names.size + m.size + LABELS.size
  puts("f~a #{total} #{area} #{names.join(",")}")
  return total
end


END
              n (modulo n 7) n (add1 (modulo n 5)) n)))
   "def main() -> Void\n  puts(f0([1, 2, 3], \"x\"))\nend\n"))

(module+ slow
  (when (vm-built? "frontend lower tests")
    (with-bytecode
      (lambda (work bytecode)
        (test-case "while Racket exists: the Agentica lowering matches the Racket lowering on tests/fixtures/vm/"
          (define paths (agc-files-in "tests/fixtures/vm"))
          (check-true (> (length paths) 200))
          (agentica-matches-racket (texts-by-path bytecode paths) paths))

        (test-case "while Racket exists: the Agentica lowering matches the Racket lowering on the programs of tests/checker-test.rkt"
          (define programs (checker-case-programs))
          (check-true (> (length programs) 400))
          (define paths
            (for/list ([text (in-list programs)] [n (in-naturals)])
              (write-file (build-path work "cases" (format "c~a.agc" n)) text)))
          (agentica-matches-racket (texts-by-path bytecode paths) paths))

        (test-case "while Racket exists: the Agentica lowering matches the Racket lowering on every std/ module and the compiler"
          (define wrappers
            (for/list ([file (in-directory stdlib-folder)] #:when (path-has-extension? file #".agc"))
              (define name (path->string (path-replace-extension (find-relative-path (simplify-path stdlib-folder) (simplify-path file)) #"")))
              (write-file (build-path work "std" (string-append (string-replace name "/" "_") ".agc"))
                          (format "import Module from \"std/~a\"\n\ndef main() -> Void\nend\n" name))))
          (define paths (append wrappers (agc-files-in "compiler")))
          (check-true (> (length paths) 50))
          (agentica-matches-racket (texts-by-path bytecode paths) paths))

        (test-case "trees at the nesting limit lower to the same IR, with a margin of VM frames"
          (define cases (deep-cases))
          (define paths
            (for/list ([entry (in-list cases)])
              (write-file (build-path work "deep" (format "~a.agc" (car entry))) (cdr entry))))
          (define outputs (texts-by-path bytecode paths))
          (agentica-matches-racket outputs paths)
          (for ([path (in-list paths)])
            (check-regexp-match #rx"^program " (hash-ref outputs path)))
          ; Lowering takes up to 3 frames for each level of the tree, about 3,000 of the 10,000 at 1,000
          ; levels. With 5,000 frames used up before it starts, every case still lowers.
          (define-values (status out err) (run-lowering bytecode paths #:flags '("--burn=5000")))
          (check-equal? err "")
          (check-equal? (parse-texts out) outputs)
          ; The control: with 8,000 frames used up the deepest cases must overflow, so the flag measures something.
          (define overflow
            (let-values ([(status out err) (run-lowering bytecode (list (car (take-right paths 3))) #:flags '("--burn=8000"))])
              (string-append out err)))
          (check-regexp-match #rx"RUNTIME-STACK-OVERFLOW" overflow))

        (test-case "a generated program of 300 functions lowers to the same IR"
          (define path (write-file (build-path work "generated.agc") (generated-program 300)))
          (agentica-matches-racket (texts-by-path bytecode (list path)) (list path)))))))
