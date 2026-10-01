#lang racket

(require (except-in rackunit check)
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

  (test-case "rejected fragments fail with the intended code"
    (check-equal? (code-of "  age: Int = \"25\"") 'CHECK-TYPE-MISMATCH)
    (check-equal? (code-of "  if 1\n    puts(\"hello\")\n  end") 'CHECK-TYPE-MISMATCH)
    (check-equal? (code-of "  values = []") 'CHECK-EMPTY-LIST-TYPE)
    (check-equal? (code-of "  puts \"hello\"") 'PARSE-UNEXPECTED-TOKEN))

  (test-case "CLI exit codes"
    (define hello (path->string (build-path examples-dir "hello.agc")))
    (check-equal? (cli hello) '(0 "hello\n" ""))
    (check-equal? (car (cli "no-such-file.agc")) 2)
    (check-equal? (cli "check" hello) '(0 "check ok\n" ""))
    (define type-error (make-temporary-file "agentica~a.agc"))
    (display-to-file "def main() -> Nil\n  puts(1)\nend\n" type-error #:exists 'truncate)
    (define checked (cli "check" (path->string type-error)))
    (delete-file type-error)
    (check-equal? (car checked) 1)
    (check-equal? (cadr checked) "")
    (check-regexp-match #rx"error\\[CHECK-" (caddr checked))
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
    (check-equal? (cli (path->string args-file) "x" "y") '(0 "x\ny\n" ""))
    (delete-file args-file)))
