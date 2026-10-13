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
  (test-case "closures reach Task.spawn through a function parameter"
    (define-values (result output)
      (run (string-append
            "def start(n: Int, f: Fn[Int, Int]) -> Task[Int]\n  return Task.spawn(f, n)\nend\n\n"
            "\ndef main() -> Void\n  offset = 100\n  task = start(5) do |n|\n    Task.sleep(0)\n    n + offset\n  end\n"
            "  offset = 0\n  IO.inspect(Task.await(task))\nend\n\n")))
    (check-equal? result (void))
    (check-equal? output "105\n"))

  (test-case "tasks infer results, retain values and isolate nested function scopes"
    (define-values (result output)
      (run (string-append
            "struct Item\n  value: Int\nend\n\n"
            "\ndef boolean(n: Int) -> Bool\n  return false\nend\n\n"
            "\ndef nothing(n: Int) -> Nil\n  return nil\nend\n\n"
            "\ndef failure(n: Int) -> Result[Int]\n  return error(\"normal result\")\nend\n\n"
            "\ndef double(n: Int) -> Int\n  Task.sleep(0)\n  return n * 2\nend\n\n"
            "\ndef nested(n: Int) -> Item\n  child = Task.spawn(&double, n)\n  value = Task.await(child)\n  return Item(value: value)\nend\n\n"
            "\ndef main() -> Void\n  n = 99\n  a: Task[Item] = Task.spawn(&nested, 21)\n"
            "  b = Task.spawn(&nested, 7)\n  IO.inspect(Task.await(a))\n  IO.inspect(Task.await(b))\n"
            "  IO.inspect(Task.await(a))\n  IO.inspect(n)\n  IO.inspect(a)\n"
            "  IO.inspect(Task.await(Task.spawn(&boolean, 0)))\n"
            "  IO.inspect(Task.await(Task.spawn(&nothing, 0)))\n"
            "  IO.inspect(Task.await(Task.spawn(&failure, 0)))\nend\n\n")))
    (check-equal? result (void))
    (check-equal? output "Item(value: 42)\nItem(value: 14)\nItem(value: 42)\n99\n<Task>\nfalse\nnil\nerror(\"normal result\")\n"))

  (test-case "task types and sleep reject invalid programs at their boundaries"
    (define prefix "def identity(n: Int) -> Int\n  return n\nend\n\n")
    (for ([entry '(("Task.spawn(&identity, \"x\")" CHECK-TYPE-MISMATCH)
                   ("Task.spawn(7, 0)" CHECK-TYPE-MISMATCH)
                   ("Task.await(7)" CHECK-TYPE-MISMATCH)
                   ("t: Task[String] = Task.spawn(&identity, 7)" CHECK-TYPE-MISMATCH)
                   ("t: Task = Task.spawn(&identity, 7)" CHECK-UNKNOWN-TYPE)
                   ("Task.spawn(&main, nil)" CHECK-TYPE-MISMATCH)
                   ("JSON.encode(Task.spawn(&identity, 0))" CHECK-NOT-ENCODABLE)
                   ("t = Task.spawn(&identity, 0)\n  t == t" CHECK-TYPE-MISMATCH))])
      (define program (checked (string-append prefix "def main() -> Void\n  " (car entry) "\nend\n\n")))
      (check-true (diagnostic? program))
      (check-equal? (diagnostic-code program) (cadr entry)))
    (define reserved (checked "struct Task\n  n: Int\nend\n\ndef main() -> Void\nend\n\n"))
    (check-equal? (diagnostic-code reserved) 'CHECK-REDEFINED-NAME)
    (define-values (negative output) (run "def main() -> Void\n  Task.sleep(-1)\nend\n\n"))
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
                    "def receive(n: Int) -> String\n  IO.warn(\"ready\")\n  return IO.gets!()\nend\n\n"
                    "\ndef double(n: Int) -> Int\n  return n * 2\nend\n\n"
                    "\ndef main() -> Void\n  waiting = Task.spawn(&receive, 0)\n  other = Task.spawn(&double, 21)\n"
                    "  puts(String.from_int(Task.await(other)))\n  IO.flush()\n  puts(Task.await(waiting))\nend\n\n") input output #:err errors))
          (check-not-false (sync/timeout 5 ready))
          (check-equal? (read-line ready) "ready")
          (check-not-false (sync/timeout 5 reader))
          (check-equal? (read-line reader) "42")
          (displayln "delivered" writer)
          (flush-output writer)
          (check-equal? (sync/timeout 5 results) (void))
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
                                   "\nend\n\ndef main() -> Void\n  t = Task.spawn(&fail, 0)\n  line = IO.gets!()\nend\n\n") input output))
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
    (define work "def work(n: Int) -> Int\n  i = 0\n  while i < n\n    i = i + 1\n  end\n  return i\nend\n\n")
    (define single (string-append work "def main() -> Void\n  t = Task.spawn(&work, 8)\n  IO.inspect(Task.await(t))\nend\n\n"))
    (define pair (string-append work "def nested(n: Int) -> Int\n  t = Task.spawn(&work, n)\n  return Task.await(t)\nend\n\ndef main() -> Void\n  a = Task.spawn(&nested, 8)\n  b = Task.spawn(&work, 8)\n  IO.inspect(Task.await(a))\n  IO.inspect(Task.await(b))\nend\n\n"))
    (define-values (one output) (run single #:max-steps 100))
    (check-equal? one (void))
    (check-equal? output "8\n")
    (define-values (two ignored) (run pair #:max-steps 100))
    (check-equal? (diagnostic-code two) 'RUNTIME-STEP-LIMIT)
    (define-values (again repeated) (run single #:max-steps 100))
    (check-equal? again (void)))

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
              (start "def wait(n: Int) -> Void\n  IO.print(\"ready\")\n  Task.sleep(60000)\nend\n\ndef main() -> Void\n  t = Task.spawn(&wait, 0)\n  line = IO.gets!()\nend\n\n" input output))
            (define worker (sync/timeout 5 writers))
            (check-true (thread? worker))
            (if interrupt?
                (kill-thread caller)
                (begin
                  (displayln "finish" writer)
                  (flush-output writer)
                  (check-equal? (sync/timeout 5 results) (void))))
            (check-not-false (sync/timeout 5 (thread-dead-evt worker)))
            (check-false (port-closed? output))))
        (lambda () (custodian-shutdown-all owner) (close-output-port writer) (close-input-port input) (close-output-port output))))))
