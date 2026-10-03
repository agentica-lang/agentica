#lang racket

(require (except-in rackunit check) racket/async-channel
         "../src/checker.rkt" "../src/diagnostic.rkt" "../src/evaluator.rkt"
         "../src/lexer.rkt" "../src/parser.rkt" "../src/source.rkt")

(define (checked text)
  (define tokens (lex (source "task.agc" text)))
  (define parsed (if (diagnostic? tokens) tokens (parse tokens)))
  (if (diagnostic? parsed) parsed (check parsed)))

(define (run text #:max-steps [limit #f])
  (define program (checked text))
  (define output (open-output-string))
  (define result
    (if (diagnostic? program) program
        (evaluate program #:out output #:max-steps limit)))
  (values result (get-output-string output)))

(define (start program input output #:err [errors (current-error-port)] #:max-steps [limit #f])
  (define results (make-async-channel))
  (define caller
    (thread (lambda () (async-channel-put results (evaluate (checked program) #:in input #:out output #:err errors #:max-steps limit)))))
  (values caller results))

(module+ test
  (test-case "HTTP handlers share global diagnostics and budget and close listeners on termination"
    (for ([body '("  n = 1 / 0" "  while true\n    Task.sleep(0)\n  end")]
          [code '(RUNTIME-DIVISION-BY-ZERO RUNTIME-STEP-LIMIT)])
      (define owner (make-custodian))
      (dynamic-wind void
        (lambda ()
          (parameterize ([current-custodian owner])
            (define-values (reader output) (make-pipe))
            (define-values (input writer) (make-pipe))
            (define-values (caller results)
              (start (string-append "def handler(request: Request, writer: HttpWriter) -> Nil\n" body
                                    "\nend\ndef main() -> Nil\n  server = Result.unwrap!(HTTP.listen(\"127.0.0.1\", 0, &handler, HTTP.server_options()))\n"
                                    "  puts(String.from_int(HTTP.local_port(server)))\n  IO.flush()\n  HTTP.wait(server)\nend\n")
                     input output #:max-steps 200))
            (check-not-false (sync/timeout 5 reader))
            (define port (string->number (read-line reader)))
            (define-values (peer-in peer-out) (tcp-connect "127.0.0.1" port))
            (display "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n" peer-out)
            (flush-output peer-out)
            (define result (sync/timeout 5 results))
            (check-true (diagnostic? result))
            (check-equal? (diagnostic-code result) code)
            (define line (source-position-line (source-span-start (diagnostic-span result))))
            (if (eq? code 'RUNTIME-DIVISION-BY-ZERO)
                (check-equal? line 2)
                (check-not-false (memv line '(2 3))))
            (check-exn exn:fail:network? (lambda () (tcp-connect "127.0.0.1" port)))
            (check-false (port-closed? output))))
        (lambda () (custodian-shutdown-all owner)))))
  (test-case "explicit server close clears supervised work before strict BDD return"
    (define prefix "def handler(request: Request, writer: HttpWriter) -> Nil\nend\ndef main() -> Nil\n  server = Result.unwrap!(HTTP.listen(\"127.0.0.1\", 0, &handler, HTTP.server_options()))\n")
    (check-equal? (evaluate (checked (string-append prefix "  HTTP.close_server(server)\nend\n"))
                           #:require-complete-tasks? #t) 'nil)
    (define pending (evaluate (checked (string-append prefix "end\n")) #:require-complete-tasks? #t))
    (check-equal? (diagnostic-code pending) 'RUNTIME-BDD-PENDING-TASKS))
  (test-case "tasks infer results, retain values and isolate nested function scopes"
    (define-values (result output)
      (run (string-append
            "struct Item\n  value: Int\nend\n"
            "def boolean(n: Int) -> Bool\n  return false\nend\n"
            "def nothing(n: Int) -> Nil\nend\n"
            "def failure(n: Int) -> Result[Int]\n  return error(\"normal result\")\nend\n"
            "def double(n: Int) -> Int\n  Task.sleep(0)\n  return n * 2\nend\n"
            "def nested(n: Int) -> Item\n  child = Task.spawn(&double, n)\n  value = Task.await(child)\n  return Item(value: value)\nend\n"
            "def main() -> Nil\n  n = 99\n  a: Task[Item] = Task.spawn(&nested, 21)\n"
            "  b = Task.spawn(&nested, 7)\n  IO.inspect(Task.await(a))\n  IO.inspect(Task.await(b))\n"
            "  IO.inspect(Task.await(a))\n  IO.inspect(n)\n  IO.inspect(a)\n"
            "  IO.inspect(Task.await(Task.spawn(&boolean, 0)))\n"
            "  IO.inspect(Task.await(Task.spawn(&nothing, 0)))\n"
            "  IO.inspect(Task.await(Task.spawn(&failure, 0)))\nend\n")))
    (check-equal? result 'nil)
    (check-equal? output "Item(value: 42)\nItem(value: 14)\nItem(value: 42)\n99\n<Task>\nfalse\nnil\nerror(\"normal result\")\n"))

  (test-case "task types and sleep reject invalid programs at their boundaries"
    (define prefix "def identity(n: Int) -> Int\n  return n\nend\n")
    (for ([entry '(("Task.spawn(&identity, \"x\")" CHECK-TYPE-MISMATCH)
                   ("Task.spawn(7, 0)" CHECK-TYPE-MISMATCH)
                   ("Task.await(7)" CHECK-TYPE-MISMATCH)
                   ("t: Task[String] = Task.spawn(&identity, 7)" CHECK-TYPE-MISMATCH)
                   ("t: Task = Task.spawn(&identity, 7)" CHECK-UNKNOWN-TYPE)
                   ("Task.spawn(&main, nil)" CHECK-TYPE-MISMATCH)
                   ("JSON.encode(Task.spawn(&identity, 0))" CHECK-NOT-ENCODABLE)
                   ("t = Task.spawn(&identity, 0)\n  t == t" CHECK-TYPE-MISMATCH))])
      (define program (checked (string-append prefix "def main() -> Nil\n  " (car entry) "\nend\n")))
      (check-true (diagnostic? program))
      (check-equal? (diagnostic-code program) (cadr entry)))
    (define reserved (checked "struct Task\n  n: Int\nend\ndef main() -> Nil\nend\n"))
    (check-equal? (diagnostic-code reserved) 'CHECK-REDEFINED-NAME)
    (define-values (negative output) (run "def main() -> Nil\n  Task.sleep(-1)\nend\n"))
    (check-equal? (diagnostic-code negative) 'RUNTIME-INVALID-DURATION)
    (check-equal? (source-position-line (source-span-start (diagnostic-span negative))) 2))

  (test-case "a task waiting for input does not prevent another task from progressing"
    (define-values (input writer) (make-pipe))
    (define-values (reader output) (make-pipe))
    (define-values (ready errors) (make-pipe))
    (define owner (make-custodian))
    (dynamic-wind void
      (lambda ()
        (parameterize ([current-custodian owner])
          (define-values (caller results)
            (start (string-append
                    "def receive(n: Int) -> String\n  IO.warn(\"ready\")\n  return IO.gets!()\nend\n"
                    "def double(n: Int) -> Int\n  return n * 2\nend\n"
                    "def main() -> Nil\n  waiting = Task.spawn(&receive, 0)\n  other = Task.spawn(&double, 21)\n"
                    "  puts(String.from_int(Task.await(other)))\n  IO.flush()\n  puts(Task.await(waiting))\nend\n") input output #:err errors))
          (check-not-false (sync/timeout 5 ready))
          (check-equal? (read-line ready) "ready")
          (check-not-false (sync/timeout 5 reader))
          (check-equal? (read-line reader) "42")
          (displayln "delivered" writer)
          (flush-output writer)
          (check-equal? (sync/timeout 5 results) 'nil)
          (check-equal? (read-line reader) "delivered")
          (check-false (port-closed? input))
          (check-false (port-closed? output))))
      (lambda ()
        (custodian-shutdown-all owner)
        (close-output-port writer)
        (close-input-port input)
        (close-output-port output)
        (close-input-port ready)
        (close-output-port errors)
        (close-input-port reader))))

  (test-case "unawaited failures and exits interrupt a main task blocked in I/O"
    (for ([body '("return 1 / 0" "System.exit(7)\n  return 0")]
          [crash? '(#t #f)])
      (define-values (input writer) (make-pipe))
      (define output (open-output-string))
      (define owner (make-custodian))
      (dynamic-wind void
        (lambda ()
          (parameterize ([current-custodian owner])
            (define-values (caller results)
              (start (string-append "def fail(n: Int) -> Int\n  Task.sleep(0)\n  " body
                                   "\nend\ndef main() -> Nil\n  t = Task.spawn(&fail, 0)\n  line = IO.gets!()\nend\n") input output))
            (define result (sync/timeout 5 results))
            (check-not-false result)
            (if crash?
                (begin
                  (check-true (diagnostic? result))
                  (check-equal? (diagnostic-code result) 'RUNTIME-DIVISION-BY-ZERO)
                  (check-equal? (source-position-line (source-span-start (diagnostic-span result))) 3))
                (begin
                  (check-true (exit-code? result))
                  (check-equal? (exit-code-code result) 7)))
            (check-false (port-closed? input))
            (check-false (port-closed? output))))
        (lambda () (custodian-shutdown-all owner) (close-output-port writer) (close-input-port input)))))

  (test-case "nested and sibling tasks share a budget that resets between executions"
    (define work "def work(n: Int) -> Int\n  i = 0\n  while i < n\n    i = i + 1\n  end\n  return i\nend\n")
    (define single (string-append work "def main() -> Nil\n  t = Task.spawn(&work, 8)\n  IO.inspect(Task.await(t))\nend\n"))
    (define pair (string-append work "def nested(n: Int) -> Int\n  t = Task.spawn(&work, n)\n  return Task.await(t)\nend\ndef main() -> Nil\n  a = Task.spawn(&nested, 8)\n  b = Task.spawn(&work, 8)\n  IO.inspect(Task.await(a))\n  IO.inspect(Task.await(b))\nend\n"))
    (define-values (one output) (run single #:max-steps 100))
    (check-equal? one 'nil)
    (check-equal? output "8\n")
    (define-values (two ignored) (run pair #:max-steps 100))
    (check-equal? (diagnostic-code two) 'RUNTIME-STEP-LIMIT)
    (define-values (again repeated) (run single #:max-steps 100))
    (check-equal? again 'nil))

  (test-case "returning or killing the evaluator cancels its sleeping tasks"
    (for ([interrupt? '(#f #t)])
      (define-values (input writer) (make-pipe))
      (define writers (make-async-channel))
      (define output
        (make-output-port 'observe-task always-evt
          (lambda (bytes start end non-block? breakable?)
            (async-channel-put writers (current-thread))
            (- end start)) void))
      (define owner (make-custodian))
      (dynamic-wind void
        (lambda ()
          (parameterize ([current-custodian owner])
            (define-values (caller results)
              (start "def wait(n: Int) -> Nil\n  IO.print(\"ready\")\n  Task.sleep(60000)\nend\ndef main() -> Nil\n  t = Task.spawn(&wait, 0)\n  line = IO.gets!()\nend\n" input output))
            (define worker (sync/timeout 5 writers))
            (check-true (thread? worker))
            (if interrupt?
                (kill-thread caller)
                (begin
                  (displayln "finish" writer)
                  (flush-output writer)
                  (check-equal? (sync/timeout 5 results) 'nil)))
            (check-not-false (sync/timeout 5 (thread-dead-evt worker)))
            (check-false (port-closed? output))))
        (lambda () (custodian-shutdown-all owner) (close-output-port writer) (close-input-port input) (close-output-port output))))))
