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

(define (run-text-io text input)
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
                    (evaluate checked #:in (open-input-string input))))))))
  (values output result))

(define (code-of body)
  (define-values (output result) (run-text (format "def main() -> Nil\n~a\nend\n" body)))
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
                   ("strings.agc" . "AGENTICA, HELLO\n8\n5\nAgentica, world\n"))])
      (define-values (output result)
        (run-text (file->string (build-path examples-dir (car entry)))))
      (check-equal? result 'nil (car entry))
      (check-equal? output (cdr entry) (car entry))))

  (test-case "echo.agc reads and echoes standard input"
    (define-values (output result)
      (run-text-io (file->string (build-path examples-dir "echo.agc")) "one\ntwo\n"))
    (check-equal? result 'nil)
    (check-equal? output "one\ntwo\n"))

  (test-case "stdio peers receive flushed replies while stdin stays open"
    (define file (make-temporary-file "agentica-stdio~a.agc"))
    (display-to-file
     (string-append
      "def main() -> Nil\n"
      "  IO.inspect(IO.eof?())\n  IO.flush()\n"
      "  data = Result.unwrap!(IO.read_bytes(2))\n"
      "  IO.print(Result.unwrap!(String.from_bytes(data)))\n  IO.flush()\n"
      "  puts(IO.gets!())\nend\n")
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
    (define unknown (cli "help" "String.to_it" "--json"))
    (check-equal? (car unknown) 2)
    (check-regexp-match #rx"String.to_int" (caddr unknown)))

  (test-case "new diagnostics retain their codes across the three printers"
    (define file (make-temporary-file "agentica-result~a.agc"))
    (dynamic-wind
      void
      (lambda ()
        (for ([entry '(("  r = error(\"bad\")" "CHECK-RESULT-TYPE")
                       ("  r = try ok(1)" "CHECK-TRY-CONTEXT")
                       ("  x = JSON.encode({1: true})" "CHECK-NOT-ENCODABLE")
                       ("  large = 1.0\n  i = 0\n  while i < 40\n    large = large * 1000000000.0\n    i = i + 1\n  end\n  x = JSON.encode(large)" "RUNTIME-JSON-ENCODE")
                       ("  r: Result[Int] = error(\"bad\")\n  x = Result.unwrap!(r)" "RUNTIME-UNWRAP-ERROR"))])
          (display-to-file (format "def main() -> Nil\n~a\nend\n" (car entry)) file #:exists 'truncate)
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
        (display-to-file "def main() -> Nil\n  while true\n  end\nend\n" file #:exists 'truncate)
        (define path (path->string file))
        (check-equal? (cli "--max-steps" "1" "check" path) '(0 "check ok\n" ""))
        (define result (cli "--json" "--max-steps" "10" path))
        (check-equal? (car result) 1)
        (check-equal? (hash-ref (string->jsexpr (caddr result)) 'code) "RUNTIME-STEP-LIMIT")
        (for ([value '("0" "-1" "1.5" "abc" "#e3")])
          (check-equal? (car (cli "--max-steps" value path)) 2)))
      (lambda () (delete-file file))))

  (test-case "CLI exit codes"
    (define hello (path->string (build-path examples-dir "hello.agc")))
    (check-equal? (cli hello) '(0 "hello\n" ""))
    (check-equal? (car (cli "no-such-file.agc")) 2)
    (check-equal? (cli "check" hello) '(0 "check ok\n" ""))
    (define type-error (make-temporary-file "agentica~a.agc"))
    (display-to-file "def main() -> Nil\n  puts(1)\nend\n" type-error #:exists 'truncate)
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
    (display-to-file "def main() -> Nil\n  x = 1 / 0\nend\n" bad #:exists 'truncate)
    (define failed (cli (path->string bad)))
    (delete-file bad)
    (check-equal? (car failed) 1)
    (check-regexp-match #rx"error\\[RUNTIME-DIVISION-BY-ZERO\\]" (caddr failed))
    (define exit-file (make-temporary-file "agentica~a.agc"))
    (display-to-file "def main() -> Nil\n  System.exit(3)\nend\n" exit-file #:exists 'truncate)
    (check-equal? (car (cli (path->string exit-file))) 3)
    (delete-file exit-file)
    (define args-file (make-temporary-file "agentica~a.agc"))
    (display-to-file
     "def main() -> Nil\n  for a in System.args()\n    puts(a)\n  end\nend\n"
     args-file #:exists 'truncate)
    (check-equal? (cli (path->string args-file) "x" "y" "--json") '(0 "x\ny\n--json\n" ""))
    (delete-file args-file)))
