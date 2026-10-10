#lang racket

(require (except-in rackunit check)
         json
         racket/runtime-path
         "../src/checker.rkt"
         "../src/diagnostic.rkt"
         "../src/evaluator.rkt"
         "../src/lexer.rkt"
         "../src/parser.rkt"
         "../src/source.rkt")

(define-runtime-path examples-dir "../examples")
(define-runtime-path main-file "../src/main.rkt")

(define (run-text text)
  (define result #f)
  (define output
    (with-output-to-string
      (lambda ()
        (set! result
              (let* ([lexed (lex (source "test.agc" text))]
                     [parsed (if (diagnostic? lexed) lexed (parse lexed))]
                     [checked (if (diagnostic? parsed) parsed (check parsed))])
                (if (diagnostic? checked) checked (evaluate checked)))))))
  (values output result))

(define (run-text-io text input #:max-steps [max-steps #f])
  (define result #f)
  (define output
    (with-output-to-string
      (lambda ()
        (set! result
              (let* ([lexed (lex (source "test.agc" text))]
                     [parsed (if (diagnostic? lexed) lexed (parse lexed))]
                     [checked (if (diagnostic? parsed) parsed (check parsed))])
                (if (diagnostic? checked)
                    checked
                    (evaluate checked #:in (open-input-string input) #:max-steps max-steps)))))))
  (values output result))

(define (code-of body)
  (define-values (output result) (run-text (format "def main() -> Void\n~a\nend\n\n" body)))
  (if (diagnostic? result) (diagnostic-code result) result))

(define (cli . arguments)
  (define-values (process out in err)
    (apply subprocess #f #f #f (find-system-path 'exec-file) (path->string main-file) arguments))
  (close-output-port in)
  (define stdout (port->string out))
  (define stderr (port->string err))
  (subprocess-wait process)
  (list (subprocess-status process) stdout stderr))

(module+ test
  (test-case "valid examples run with the expected output"
    (for ([entry '(("hello.agc" . "hello\n")
                   ("classify.agc" . "adult\n")
                   ("result.agc" . "42\nempty count\n0\n")
                   ("json.agc" . "{\"name\":\"Ana\",\"age\":25}\nhello, Ana\nmissing name\n")
                   ("tasks.agc" . "Probar Agentica\n")
                   ("inventory.agc" . "apple\nkiwi\n")
                   ("strings.agc" . "AGENTICA, HELLO\n8\n5\nAgentica, world\n")
                   ("blocks.agc" . "cocoa: 3.0\ntea: 4.0\nunits: 15\nany empty: true\n"))])
      (define-values (output result)
        (run-text (file->string (build-path examples-dir (car entry)))))
      (check-equal? result (void) (car entry))
      (check-equal? output (cdr entry) (car entry))))

  (test-case "echo.agc reads and echoes standard input"
    (define-values (output result)
      (run-text-io (file->string (build-path examples-dir "echo.agc")) "one\ntwo\n"))
    (check-equal? result (void))
    (check-equal? output "one\ntwo\n"))

  (test-case "JSON examples validate documents and recover within streams"
    (for ([entry '(("json-config.agc"
                    "{\"service\":{\"name\":\"api\",\"port\":8080,\"enabled\":false}}"
                    "{\"name\":\"api\",\"port\":8080,\"enabled\":false}\n")
                   ("json-config.agc"
                    "{\"service\":{\"name\":\"api\",\"port\":0,\"enabled\":true}}"
                    "{\"error\":\"invalid config\"}\n")
                   ("json-expenses.agc"
                    "[{\"category\":\"food\",\"amount\":1200},{\"category\":\"travel\",\"amount\":500},{\"category\":\"food\",\"amount\":-200}]"
                    "{\"totals\":{\"food\":1000,\"travel\":500}}\n")
                   ("json-expenses.agc"
                    "[{\"category\":\"food\",\"amount\":true}]"
                    "{\"error\":\"invalid expense\"}\n")
                   ("json-lines.agc"
                    "{\"name\":\"Ana\",\"score\":75,\"active\":true}\nnot json\n{\"name\":\"Luis\",\"score\":60,\"active\":false}\n"
                    "{\"name\":\"Ana\",\"passed\":true}\n{\"error\":\"invalid record\"}\n{\"name\":\"Luis\",\"passed\":false}\n")
                   ("json-lines.agc"
                    "{\"name\":\"Ana\",\"score\":101,\"active\":true}\n"
                    "{\"error\":\"invalid record\"}\n"))])
      (define-values (output result)
        (run-text-io (file->string (build-path examples-dir (car entry))) (cadr entry)))
      (check-equal? result (void) (car entry))
      (check-equal? output (caddr entry) (car entry))))

  (test-case "knight tours cover every square exactly once with legal moves"
    (define program (file->string (build-path examples-dir "knight-tour.agc")))
    (for ([entry '((1 0) (5 0) (8 0) (8 27))])
      (define size (car entry))
      (define start (cadr entry))
      (define-values (out result)
        (run-text-io program (jsexpr->string (hasheq 'size size 'start start)) #:max-steps 5000000))
      (check-equal? result (void))
      (define data (string->jsexpr out))
      (check-true (hash-ref data 'found))
      (define path (hash-ref data 'path))
      (check-equal? (car path) start)
      (check-equal? (sort path <) (range (* size size)))
      (for ([from (in-list path)] [to (in-list (cdr path))])
        (define dx (abs (- (remainder from size) (remainder to size))))
        (define dy (abs (- (quotient from size) (quotient to size))))
        (check-equal? (sort (list dx dy) <) '(1 2))))
    (define-values (out result)
      (run-text-io program "{\"size\":3,\"start\":0}" #:max-steps 5000000))
    (check-equal? result (void))
    (check-equal? (string->jsexpr out) (hasheq 'found #f 'path '())))

  (test-case "traveling salesman returns an optimal complete circuit"
    (define program (file->string (build-path examples-dir "traveling-salesman.agc")))
    (for ([entry '((((0)) 0)
                   (((0 10 15 20) (10 0 35 25) (15 35 0 30) (20 25 30 0)) 80)
                   (((0 1 9) (9 0 1) (1 9 0)) 3)
                   (((0 1 2 2) (1 0 1 2) (2 1 0 100) (2 2 100 0)) 7)
                   (((0 0 0) (0 0 0) (0 0 0)) 0)
                   (((0 1000000000) (1000000000 0)) 2000000000))])
      (define matrix (car entry))
      (define-values (out result)
        (run-text-io program (jsexpr->string (hasheq 'distances matrix)) #:max-steps 5000000))
      (check-equal? result (void))
      (define data (string->jsexpr out))
      (define route (hash-ref data 'route))
      (check-equal? (hash-ref data 'cost) (cadr entry))
      (check-equal? (car route) 0)
      (check-equal? (last route) 0)
      (check-equal? (sort (drop-right route 1) <) (range (length matrix)))
      (check-equal? (for/sum ([from (in-list route)] [to (in-list (cdr route))])
                      (list-ref (list-ref matrix from) to))
                    (hash-ref data 'cost))))

  (test-case "maze BFS returns shortest legal paths and reports unreachable goals"
    (define program (file->string (build-path examples-dir "maze-bfs.agc")))
    (for ([entry (append '(((".") 0 0 0)
                          (("....") 3 0 3)
                          (("..." "...") 2 3 3)
                          ((".#." "...") 0 2 4)
                          (("..." "..." "...") 0 8 4)
                          ((".#." "###" "...") 0 8 -1))
                        (list (list (make-list 32 (make-string 32 #\.)) 0 1023 62)))])
      (define grid (car entry))
      (define start (cadr entry))
      (define goal (caddr entry))
      (define expected-distance (cadddr entry))
      (define width (string-length (car grid)))
      (define-values (out result)
        (run-text-io program (jsexpr->string (hasheq 'grid grid 'start start 'goal goal))
                     #:max-steps 5000000))
      (check-equal? result (void))
      (define data (string->jsexpr out))
      (check-equal? (hash-ref data 'found) (>= expected-distance 0))
      (check-equal? (hash-ref data 'distance) expected-distance)
      (define path (hash-ref data 'path))
      (if (< expected-distance 0)
          (check-equal? path '())
          (begin
            (check-equal? (length path) (add1 expected-distance))
            (check-equal? (car path) start)
            (check-equal? (last path) goal)
            (check-equal? (length (remove-duplicates path)) (length path))
            (for ([square (in-list path)])
              (check-true (and (exact-integer? square) (<= 0 square)
                               (< square (* width (length grid)))))
              (check-equal? (string-ref (list-ref grid (quotient square width))
                                       (remainder square width)) #\.))
            (for ([from (in-list path)] [to (in-list (cdr path))])
              (check-equal? (+ (abs (- (quotient from width) (quotient to width)))
                              (abs (- (remainder from width) (remainder to width))))
                            1))))))

  (test-case "algorithm examples reject malformed input before producing a solution"
    (define maze-program (file->string (build-path examples-dir "maze-bfs.agc")))
    (for ([grid (list (list (make-string 33 #\.)) (make-list 33 "."))])
      (define-values (out result)
        (run-text-io maze-program (jsexpr->string (hasheq 'grid grid 'start 0 'goal 0))
                     #:max-steps 5000000))
      (check-equal? result (void))
      (check-equal? (string->jsexpr out) (hasheq 'error "invalid input")))
    (for ([entry '(("maze-bfs.agc" "not JSON" "{\"grid\":[],\"start\":0,\"goal\":0}"
                   "{\"grid\":[\"\"],\"start\":0,\"goal\":0}"
                   "{\"grid\":[\"..\",\".\"],\"start\":0,\"goal\":1}"
                   "{\"grid\":[\"..\",\".x\"],\"start\":0,\"goal\":1}"
                   "{\"grid\":[\"..\",false],\"start\":0,\"goal\":1}"
                   "{\"grid\":[\"..\"],\"start\":true,\"goal\":1}"
                   "{\"grid\":[\"..\"],\"start\":0,\"goal\":1.0}"
                   "{\"grid\":[\"..\"],\"start\":-1,\"goal\":1}"
                   "{\"grid\":[\"..\"],\"start\":0,\"goal\":2}"
                   "{\"grid\":[\"#.\"],\"start\":0,\"goal\":1}"
                   "{\"grid\":[\".#\"],\"start\":0,\"goal\":1}"
                   "{\"grid\":[\"..\"],\"start\":0}")
                  ("knight-tour.agc" "not JSON" "{\"size\":0,\"start\":0}"
                   "{\"size\":9,\"start\":0}" "{\"size\":8,\"start\":64}"
                   "{\"size\":8,\"start\":-1}" "{\"size\":true,\"start\":0}" "{\"size\":8}")
                  ("traveling-salesman.agc" "not JSON" "{\"distances\":[]}"
                   "{\"distances\":[[0,1],[1]]}" "{\"distances\":[[1]]}"
                   "{\"distances\":[[0,-1],[1,0]]}" "{\"distances\":[[0,1],[false,0]]}"
                   "{\"distances\":[[0,1],[1,0.0]]}" "{\"distances\":[[0,1000000001],[1,0]]}"))])
      (define program (file->string (build-path examples-dir (car entry))))
      (for ([input (in-list (cdr entry))])
        (define-values (out result) (run-text-io program input #:max-steps 5000000))
        (check-equal? result (void))
        (check-equal? (string->jsexpr out) (hasheq 'error "invalid input")))))

  (test-case "stdio peers receive flushed replies while stdin stays open"
    (define file (make-temporary-file "agentica-stdio~a.agc"))
    (display-to-file
     (string-append
      "def main() -> Void\n"
      "  IO.inspect(IO.eof?())\n  IO.flush()\n"
      "  data = Result.unwrap!(IO.read_bytes(2))\n"
      "  IO.print(Result.unwrap!(String.from_bytes(data)))\n  IO.flush()\n"
      "  puts(IO.gets!())\nend\n\n")
     file #:exists 'truncate)
    (define-values (process out in err)
      (subprocess #f #f #f (find-system-path 'exec-file) (path->string main-file) (path->string file)))
    (dynamic-wind
      void
      (lambda ()
        ;; Only the first byte of ñ is available. EOF peeking must not decode it.
        (write-byte 195 in)
        (flush-output in)
        (check-not-false (sync/timeout 10 out) "initial reply was not flushed, or EOF peeking blocked on UTF-8")
        (check-equal? (read-line out) "false")
        (check-equal? (subprocess-status process) 'running)
        (write-byte 177 in)
        (flush-output in)
        (check-not-false (sync/timeout 10 out) "response remained buffered")
        (check-equal? (read-char out) #\ñ)
        (check-equal? (subprocess-status process) 'running)
        (display "done\n" in)
        (close-output-port in)
        (check-not-false (sync/timeout 10 process) "stdio program did not finish")
        (subprocess-wait process)
        (check-equal? (subprocess-status process) 0)
        (check-equal? (port->string out) "done\n")
        (check-equal? (port->string err) ""))
      (lambda ()
        (when (eq? (subprocess-status process) 'running) (subprocess-kill process #t))
        (subprocess-wait process)
        (unless (port-closed? in) (close-output-port in))
        (close-input-port out)
        (close-input-port err)
        (delete-file file))))

  (test-case "rejected fragments fail with the intended code"
    (check-equal? (code-of "  age: Int = \"25\"") 'CHECK-TYPE-MISMATCH)
    (check-equal? (code-of "  if 1\n    puts(\"hello\")\n  end") 'CHECK-TYPE-MISMATCH)
    (check-equal? (code-of "  values = []") 'CHECK-EMPTY-LIST-TYPE)
    (check-equal? (code-of "  puts \"hello\"") 'PARSE-UNEXPECTED-TOKEN))

  (test-case "help reads the catalog without a source file"
    (define help (cli "help" "String.to_int" "--json"))
    (check-equal? (car help) 0)
    (check-equal? (caddr help) "")
    (define data (string->jsexpr (cadr help)))
    (check-equal? (hash-ref data 'arity) 1)
    (check-equal? (hash-ref data 'result) "Result[Int]")
    (check-equal? (hash-ref data 'parameters) (list (hasheq 'name "s" 'type "String")))
    (check-equal? (hash-ref data 'effects) '())
    (check-equal? (cli "--json" "help" "String.to_int") help)
    (check-equal? (cli "--max-steps" "10" "help" "String.to_int" "--json") help)
    (define get-help (cli "help" "Map.get" "--json"))
    (check-equal? (car get-help) 0)
    (check-equal? (caddr get-help) "")
    (define variants (hash-ref (string->jsexpr (cadr get-help)) 'overloads))
    (check-equal? (map (lambda (variant) (hash-ref variant 'arity)) variants) '(2 3))
    (check-equal? (map (lambda (variant) (hash-ref variant 'result)) variants) '("Result[V]" "V"))
    (define get-text (cli "help" "Map.get"))
    (check-equal? (car get-text) 0)
    (check-regexp-match #rx"Map.get\\(map: Map\\[K, V\\], key: K\\) -> Result\\[V\\]" (cadr get-text))
    (check-regexp-match #rx"default: V\\) -> V" (cadr get-text))
    (define unknown (cli "help" "String.to_it" "--json"))
    (check-equal? (car unknown) 2)
    (check-regexp-match #rx"String.to_int" (caddr unknown)))

  (test-case "new diagnostics retain their codes across the three printers"
    (define file (make-temporary-file "agentica-result~a.agc"))
    (dynamic-wind
      void
      (lambda ()
        (for ([entry '(("  x = List.repeat(1, -1)" "RUNTIME-INVALID-COUNT")
                       ("  r = error(\"bad\")" "CHECK-RESULT-TYPE")
                       ("  r = try ok(1)" "CHECK-TRY-CONTEXT")
                       ("  x = JSON.encode({1: true})" "CHECK-NOT-ENCODABLE")
                       ("  large = 1.0\n  i = 0\n  while i < 40\n    large = large * 1000000000.0\n    i = i + 1\n  end\n  x = JSON.encode(large)" "RUNTIME-JSON-ENCODE")
                       ("  r: Result[Int] = error(\"bad\")\n  x = Result.unwrap!(r)" "RUNTIME-UNWRAP-ERROR"))])
          (display-to-file (format "def main() -> Void\n~a\nend\n\n" (car entry)) file #:exists 'truncate)
          (for ([style '("plain" "--ai" "--json")])
            (define args (if (equal? style "plain") '() (list style)))
            (define result (apply cli (append args (list (path->string file)))))
            (check-equal? (car result) 1)
            (check-equal? (cadr result) "")
            (if (equal? style "--json")
                (let ([data (string->jsexpr (caddr result))])
                  (check-equal? (hash-ref data 'code) (cadr entry))
                  (check-true (hash-has-key? data 'range)))
                (check-true (string-contains? (caddr result) (cadr entry)))))))
      (lambda () (delete-file file))))

  (test-case "CLI budget validation and checking do not run the program"
    (define file (make-temporary-file "agentica-budget~a.agc"))
    (dynamic-wind
      void
      (lambda ()
        (display-to-file "def main() -> Void\n  while true\n  end\nend\n\n" file #:exists 'truncate)
        (define path (path->string file))
        (check-equal? (cli "--max-steps" "1" "check" path) '(0 "check ok\n" ""))
        (define result (cli "--json" "--max-steps" "10" path))
        (check-equal? (car result) 1)
        (check-equal? (hash-ref (string->jsexpr (caddr result)) 'code) "RUNTIME-STEP-LIMIT")
        (for ([value '("0" "-1" "1.5" "abc" "#e3")])
          (check-equal? (car (cli "--max-steps" value path)) 2)))
      (lambda () (delete-file file))))

  (test-case "CLI --version prints the version and exits 0"
    (check-equal? (cli "--version") (list 0 "0.1.0\n" "")))

  (test-case "CLI --seed repeats Random and rejects bad seeds"
    (define program (make-temporary-file "agentica~a.agc"))
    (display-to-file "def main() -> Void\n  IO.inspect([Random.int(1, 1000000), Random.int(1, 1000000)])\nend\n\n"
                     program #:exists 'truncate)
    (define path (path->string program))
    (define first (cli "--seed" "5" path))
    (define again (cli "--seed" "5" path))
    (define bad (cli "--seed" "2147483648" path))
    (delete-file program)
    (check-equal? (car first) 0)
    (check-equal? first again)
    (check-equal? (car bad) 2))

  (test-case "CLI exit codes"
    (define hello (path->string (build-path examples-dir "hello.agc")))
    (check-equal? (cli hello) '(0 "hello\n" ""))
    (check-equal? (car (cli "no-such-file.agc")) 2)
    (check-equal? (cli "check" hello) '(0 "check ok\n" ""))
    (define type-error (make-temporary-file "agentica~a.agc"))
    (display-to-file "def main() -> Void\n  x: String = 1\nend\n\n" type-error #:exists 'truncate)
    (define checked (cli "check" (path->string type-error)))
    (define ai (cli "--ai" "check" (path->string type-error)))
    (define json (cli "--json" "check" (path->string type-error)))
    (delete-file type-error)
    (check-equal? (car checked) 1)
    (check-equal? (cadr checked) "")
    (check-regexp-match #rx"error\\[CHECK-" (caddr checked))
    (check-equal? (car ai) 1)
    (check-regexp-match #rx"^check failed: 1 error\n\n\\[CHECK-" (caddr ai))
    (check-equal? (car json) 1)
    (check-equal? (hash-ref (string->jsexpr (caddr json)) 'code) "CHECK-TYPE-MISMATCH")
    (check-equal? (cadr json) "")
    (check-equal? (cli "--json" "check" hello) '(0 "{\"ok\":true}\n" ""))
    (define bad (make-temporary-file "agentica~a.agc"))
    (display-to-file "def main() -> Void\n  x = 1 / 0\nend\n\n" bad #:exists 'truncate)
    (define failed (cli (path->string bad)))
    (delete-file bad)
    (check-equal? (car failed) 1)
    (check-regexp-match #rx"error\\[RUNTIME-DIVISION-BY-ZERO\\]" (caddr failed))
    (define exit-file (make-temporary-file "agentica~a.agc"))
    (display-to-file "def main() -> Void\n  System.exit(3)\nend\n\n" exit-file #:exists 'truncate)
    (check-equal? (car (cli (path->string exit-file))) 3)
    (delete-file exit-file)
    (define args-file (make-temporary-file "agentica~a.agc"))
    (display-to-file
     "def main() -> Void\n  for a in System.args()\n    puts(a)\n  end\nend\n\n"
     args-file #:exists 'truncate)
    (check-equal? (cli (path->string args-file) "x" "y" "--json") '(0 "x\ny\n--json\n" ""))
    (delete-file args-file)))
