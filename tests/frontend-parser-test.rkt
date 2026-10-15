#lang racket

(require rackunit
         racket/runtime-path
         "frontend-parser-common.rkt"
         (only-in "frontend-lexer-common.rkt" call-with-bytecode diagnostic-line)
         "vm-diff-common.rkt"
         "../src/source-file.rkt")

(define-runtime-path root "..")
(define-runtime-path entry "../compiler/parse.agc")

(define nesting-limit 1000)

(define (read-text path)
  (file->string (build-path root path)))

(define (golden input)
  (file->string (golden-file input)))

(define (run-parser bytecode paths)
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

(define (check-against-racket outputs paths)
  (for ([path (in-list paths)])
    (define text (read-source-file (path->complete-path path root) path))
    (check-pred string? text path)
    (when (string? text)
      (check-equal? (hash-ref outputs path #f) (string-append (parser-text text) "\n") path))))

(define snippets
  '("x = 1" "x = a + b * c" "y = f(x, 1)" "z = xs.map do |v| v + 1 end" "puts(\"a#{x}b\")" "x += 2"
    "return x" "return" "n = xs[0].size" "p = a |> f(1) |> try g()" "r = 0...n + 1" "m = {\"k\": 1, \"j\": 2}"
    "l = [1, 2, [3]]" "w = Point(x: 1, y: Foo.Bar(2))" "v = Option.Some(3)" "q = -a and not b || c" "h = &Util.helper"
    "t = try ok(1) + 2" "s = Result.Ok(5)" "f = xs.each do |a, b: Int|\n    puts(a)\n  end"
    "if x\n    y = 1\n  elsif z\n    y = 2\n  else\n    y = 3\n  end"
    "while x < 3 do\n    x += 1\n    next\n  end"
    "for i in 0...3\n    puts(i)\n    break\n  end"
    "case x\n    1 -> puts(1)\n    -2 -> puts(2)\n    Option.Some(a) ->\n      puts(a)\n    ok(v) -> puts(v)\n    _ -> puts(0)\n  end"
    "case x do\n    _ -> puts(0)\n  end"
    "z = (a\n    |> f()\n    |> g())"))

(define declarations
  '("def helper(a: Int, b: List[Map[String, Int]],) -> Result[Int]\n  return ok(a)\nend\n\n"
    "## Doc.\nstruct P\n  ## Field.\n  a: Int\n  b: Util.T\nend\n\n"
    "export enum E[T]\n  ## Variant.\n  A(T)\n  B(T, Int)\n  C\nend\n\n"
    "import Util from \"util\"\n"
    "export def ready?() -> Bool\n  return true\nend\n\n"
    "enum Plain\n  A\nend\n\n"))

(define risky
  '("" " " "\n" "\n\n" "  " "end" "def " "do" "|x|" "(" ")" "[" "]" "{" "}" "," ":" "." "->" "=" "==" "<" "|>" "..." ".."
    "\"" "\"a#{" "}" "#{" "## d\n" "# c\n" "if " "elsif " "else" "case " "_ ->" "ok(" "error(" "Result." "Option.Some(" "try "
    "not " "-" "!" "&" "99999999999999999999" "0.5" "\r\n" "\t" "é" "\U0001F600" ";" "@"))

(define (mutate text pick-int)
  (define size (string-length text))
  (define at (if (zero? size) 0 (pick-int (add1 size))))
  (case (pick-int 5)
    [(0) (substring text 0 at)]
    [(1) (if (< at size)
             (string-append (substring text 0 at) (substring text (min size (+ at 1 (pick-int 6)))))
             text)]
    [(2) (string-append (substring text 0 at) (list-ref risky (pick-int (length risky))) (substring text at))]
    [(3) (if (< at size)
             (string-append (substring text 0 at)
                            (string (string-ref text (pick-int size)))
                            (substring text (add1 at)))
             text)]
    [else
     (define other (if (zero? size) 0 (pick-int size)))
     (string-append (substring text 0 (min at other)) (substring text (max at other)))]))

(define (generated-cases)
  (parameterize ([current-pseudo-random-generator (make-pseudo-random-generator)])
    (random-seed 241)
    (define (pick-int n) (random n))
    (define (pick items) (list-ref items (pick-int (length items))))
    (define (program)
      (define body
        (string-join (for/list ([_ (in-range (+ 1 (pick-int 6)))]) (string-append "  " (pick snippets))) "\n"))
      (string-append (apply string-append (for/list ([_ (in-range (pick-int 3))]) (pick declarations)))
                     "def main() -> Void\n" body "\nend\n\n"))
    (append
     (for/list ([_ (in-range 100)]) (program))
     (for/list ([_ (in-range 150)])
       (for/fold ([text (program)]) ([_ (in-range (+ 1 (pick-int 3)))]) (mutate text pick-int)))
     (for/list ([_ (in-range 50)])
       (string-append* (for/list ([_ (in-range (+ 3 (pick-int 12)))])
                        (if (< (pick-int 10) 4) (pick risky) (string-append (pick snippets) "\n"))))))))

(define (repeat text count) (string-append* (make-list count text)))

(define (function-body body) (string-append "def main() -> Void\n" body "end\n\n"))

(define (nesting-shapes count)
  (list
   (cons "parentheses" (function-body (string-append "  x = " (repeat "(" count) "1" (repeat ")" count) "\n")))
   (cons "prefix operators" (function-body (string-append "  x = " (repeat "- " count) "1\n")))
   (cons "calls" (function-body (string-append "  x = " (repeat "f(" count) "1" (repeat ")" count) "\n")))
   (cons "lists" (function-body (string-append "  x = " (repeat "[" count) "1" (repeat "]" count) "\n")))
   (cons "if statements" (function-body (string-append (repeat "if x\n" count) "puts(1)\n" (repeat "end\n" count))))
   (cons "blocks" (function-body (string-append (repeat "xs.each do |x|\n" count) "puts(1)\n" (repeat "end\n" count))))
   (cons "types" (string-append "def f(a: " (repeat "List[" count) "Int" (repeat "]" count) ") -> Void\nend\n\n"))
   (cons "binary chain" (function-body (string-append "  x = 1" (repeat " + 1" count) "\n")))
   (cons "mixed chain" (function-body (string-append "  x = 1 * 1 or 1" (repeat " + 1" count) " < 1 and (1" (repeat " * 1" count) ")\n")))
   (cons "field chain" (function-body (string-append "  x = a" (repeat ".b" count) "\n")))
   (cons "pipe chain" (function-body (string-append "  x = a" (repeat " |> f()" count) "\n")))
   (cons "interpolations" (function-body (string-append "  x = " (repeat "\"#{" count) "1" (repeat "}\"" count) "\n")))))

;; The levels of a shape that still parse, as far as the tested sizes (300, 900, 1001, 3000) can tell. A shape
;; costs one counted level per level written (the exact edge is a few levels under the limit, which the
;; boundary cases cover), except a do block: its statement, expression, `.each` link and body each count, so
;; only 249 fit.
(define (deepest-legal shape)
  (if (equal? shape "blocks") 249 nesting-limit))

(define (with-bytecode proc) (call-with-bytecode compile-file entry proc))

(define (write-case work name text)
  (define path (path->string (build-path work name)))
  (display-to-file text path)
  path)

(module+ test
  (define inputs (parser-inputs))

  (test-case "every input has a golden and no golden is left over"
    (define expected (sort (map (lambda (input) (path->string (file-name-from-path (golden-file input)))) inputs) string<?))
    (define found
      (sort (for/list ([file (in-list (directory-list (path-only (golden-file (car inputs)))))]
                       #:when (path-has-extension? file #".ast"))
              (path->string file))
            string<?))
    (check-equal? found expected))

  (test-case "the Racket printer matches its goldens"
    (for ([input (in-list inputs)])
      (check-equal? (string-append (parser-text (read-text (parser-input-path input))) "\n")
                    (golden input)
                    (parser-input-name input))))

  (when (vm-built? "frontend parser tests")
    (with-bytecode
      (lambda (work bytecode)
        (define outputs (run-parser bytecode (map parser-input-path inputs)))
        (test-case "the Agentica parser matches the goldens on the VM"
          (for ([input (in-list inputs)])
            (check-equal? (hash-ref outputs (parser-input-path input) #f) (golden input) (parser-input-name input))))

        (test-case "chains, prefix operators and nested chains are legal at the limit and refused one past it"
          ; The trees of the legal cases print about 1 MB each, so they are checked here and not kept as goldens.
          (define shapes
            (list (list "mixed" 998 (lambda (n) (function-body (string-append "  y = x * x" (repeat " + x" n) "\n"))))
                  (list "prefix" 998 (lambda (n) (function-body (string-append "  y = " (repeat "- " n) "x\n"))))
                  (list "field" 998 (lambda (n) (function-body (string-append "  y = x" (repeat ".b" n) "\n"))))
                  (list "method" 997 (lambda (n) (function-body (string-append "  y = x" (repeat ".f(1)" n) "\n"))))
                  (list "nested" 988
                        (lambda (n)
                          (function-body (string-append "  y = x + (x + (x + (x + (x + (x" (repeat " + x" n) ")))))\n"))))))
          (define cases
            (for*/list ([shape (in-list shapes)] [n (in-list (list (second shape) (add1 (second shape))))])
              (define text ((third shape) n))
              (list (first shape) n text (write-case work (format "limit-~a-~a.agc" (first shape) n) text))))
          (define outputs (run-parser bytecode (map fourth cases)))
          (for ([entry (in-list cases)])
            (define legal? (= (second entry) (second (assoc (first entry) shapes))))
            (define label (format "~a ~a" (first entry) (second entry)))
            (define agentica (hash-ref outputs (fourth entry)))
            (define racket (parser-text (third entry)))
            (check-equal? (regexp-match? #rx"^program " racket) legal? label)
            (check-equal? agentica (string-append racket "\n") label)))

        (test-case "a file with invalid UTF-8 is LEX-INVALID-UTF8 at the first bad byte, as in Racket"
          (define path (path->string (build-path work "invalid.agc")))
          (call-with-output-file path (lambda (out) (write-bytes #"# caf\303\251\ndef \377\n" out)))
          (check-equal? (hash-ref (run-parser bytecode (list path)) path)
                        (string-append (diagnostic-line (read-source-file path path)) "\n")))

        (test-case "the first node id can be chosen, so modules can share one numbering"
          (define path "tests/fixtures/frontend/parser/synthetic.input")
          (define shifted (run-parser bytecode (list "--first-id=1000" path)))
          (check-equal? (hash-ref shifted path #f) (string-append (parser-text (read-text path) #:first-id 1000) "\n"))
          (check-true (string-contains? (hash-ref shifted path) " #1000 ")))

        (test-case "a second file continues the numbering from Ast.next_free_id of the first"
          (define first-path "tests/fixtures/frontend/parser/hello.input")
          (define second-path "tests/fixtures/frontend/parser/synthetic.input")
          (define continued (run-parser bytecode (list "--continue" first-path second-path)))
          (define first-text (parser-text (read-text first-path)))
          (define first-program-id (string->number (cadr (regexp-match #rx"^program #([0-9]+) " first-text))))
          (check-equal? (hash-ref continued first-path) (string-append first-text "\n"))
          (check-equal? (hash-ref continued second-path)
                        (string-append (parser-text (read-text second-path) #:first-id (add1 first-program-id)) "\n")))))))

(module+ slow
  (when (vm-built? "frontend parser tests")
    (with-bytecode
      (lambda (work bytecode)
        (define live-paths (racket-files '("examples" "stdlib" "tests/fixtures/vm")))
        (define generated-paths
          (for/list ([text (in-list (generated-cases))] [n (in-naturals)])
            (write-case work (format "case-~a.agc" n) text)))
        (define boundary-cases
          (for*/list ([count (in-range (- nesting-limit 5) (+ nesting-limit 4))]
                      [shape (in-list (nesting-shapes count))]
                      #:when (member (car shape) '("parentheses" "types" "binary chain" "mixed chain")))
            (write-case work (format "boundary-~a-~a.agc" (car shape) count) (cdr shape))))
        (define outputs (run-parser bytecode (append live-paths generated-paths boundary-cases)))

        (test-case "while Racket exists: the Agentica parser matches the Racket parser on examples/, stdlib/ and tests/fixtures/vm/"
          (check-against-racket outputs live-paths))

        (test-case "while Racket exists: the Agentica parser matches the Racket parser on 300 generated inputs"
          (check-against-racket outputs generated-paths)
          (define errors
            (for/sum ([path (in-list generated-paths)])
              (if (regexp-match? #rx"^ERROR" (hash-ref outputs path)) 1 0)))
          (check-true (< 30 errors 270) (format "~a of 300 generated inputs are errors" errors)))

        (test-case "the nesting limit falls at the same token in both parsers"
          (check-against-racket outputs boundary-cases)
          (define results
            (for/list ([path (in-list boundary-cases)])
              (regexp-match? #rx"^ERROR PARSE-TOO-DEEP" (hash-ref outputs path))))
          (check-true (and (memq #t results) (memq #f results) #t) "the boundary cases cross the limit"))

        (test-case "nesting far below and above the limit gives the same tree or the same PARSE-TOO-DEEP"
          (define cases
            (for*/list ([count (in-list (list 300 900 (add1 nesting-limit) 3000))]
                        [shape (in-list (nesting-shapes count))])
              (list (car shape) count (write-case work (format "nest-~a-~a.agc" (car shape) count) (cdr shape)))))
          (define nested (run-parser bytecode (map third cases)))
          (check-against-racket nested (map third cases))
          (for ([entry (in-list cases)])
            (check-equal? (regexp-match? #rx"^ERROR PARSE-TOO-DEEP" (hash-ref nested (third entry)))
                          (> (second entry) (deepest-legal (first entry)))
                          (format "~a ~a" (first entry) (second entry)))))

        (test-case "a large file parses in linear time"
          (define paths
            (list (write-case work "statements.agc" (function-body (repeat "  x = f(1, 2) + 3\n" 10000)))
                  (write-case work "items.agc" (function-body (string-append "  x = [" (repeat "1, " 20000) "1]\n")))
                  (write-case work "branches.agc"
                              (function-body (string-append "  if x\n  end\n" (repeat "  if x\n    y = 1\n  elsif x\n    y = 2\n  end\n" 3000))))
                  (write-case work "flat.agc"
                              (string-append* (for/list ([n (in-range 400)])
                                                (format "def f~a(a: Int) -> Int\n  return a + ~a\nend\n\n" n n))))))
          (define started (current-inexact-milliseconds))
          (define large (run-parser bytecode paths))
          (check-true (< (- (current-inexact-milliseconds) started) 60000))
          (check-against-racket large paths))))))
