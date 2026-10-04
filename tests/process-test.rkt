#lang racket

(require (except-in rackunit check) racket/runtime-path racket/system json
         "../src/lexer.rkt" "../src/parser.rkt" "../src/checker.rkt"
         "../src/source.rkt" "../src/diagnostic.rkt" "../src/evaluator.rkt")

(define-runtime-path peer "fixtures/process-peer.js")
(define-runtime-path main-file "../src/main.rkt")
(define node (find-executable-path "node"))

(define (compile-program text)
  (define tokens (lex (source "process.agc" text)))
  (define parsed (if (diagnostic? tokens) tokens (parse tokens)))
  (define checked (if (diagnostic? parsed) parsed (check parsed)))
  (when (diagnostic? checked) (error 'process-test (format-diagnostic checked)))
  checked)

(define (spawn mode [extra ""])
  (format "  p = Result.unwrap!(Process.spawn(~s, [~s, ~s~a], 5000))\n"
          (path->string node) (path->string peer) mode extra))

(define (program mode body [prefix ""] [extra ""])
  (string-append prefix "def main() -> Void\n" (spawn mode extra) body "\nend\n"))

(define (run text #:allowed? [allowed? #t] #:limit [limit #f])
  (define checked (compile-program text))
  (define out (open-output-string))
  (define err (open-output-string))
  (define ready (make-channel))
  (define worker
    (thread (lambda ()
              (channel-put ready (evaluate checked #:out out #:err err
                                           #:allow-run allowed? #:max-steps limit)))))
  (define result (sync/timeout 15 ready))
  (unless result (kill-thread worker) (error 'process-test "execution timed out"))
  (values result (get-output-string out) (get-output-string err)))

(define (output text [expected ""])
  (define-values (result out err) (run text))
  (check-pred void? result)
  (check-equal? err expected)
  out)

(define (alive? pid)
  (parameterize ([current-output-port (open-output-nowhere)]
                 [current-error-port (open-output-nowhere)])
    (system* node peer "probe" (string-trim pid))))

(define (cli . args)
  (define executable (getenv "AGENTICA_TEST_EXECUTABLE"))
  (define-values (child out in err)
    (apply subprocess #f #f #f (if executable (path->complete-path executable) (find-executable-path "racket"))
           (append (if executable '() (list (path->string main-file))) args)))
  (dynamic-wind void
    (lambda ()
      (close-output-port in)
      (define text (port->string out))
      (define errors (port->string err))
      (subprocess-wait child)
      (list (subprocess-status child) text errors))
    (lambda ()
      (subprocess-kill child #t)
      (close-input-port out)
      (close-input-port err))))

(module+ test
  (cond
    [(not node)
     (if (getenv "CI") (error 'process-test "Node.js is required in CI")
         (displayln "SKIP process integration: Node.js is unavailable"))]
    [else
     (test-case "CLI capability guards execution while check and help work without it"
       (define path (make-temporary-file "agentica-process~a.agc"))
       (dynamic-wind void
         (lambda ()
           (display-to-file (program "args"
             "  puts(Result.unwrap!(Process.read_line(p, 5000)))\n  IO.inspect(System.args())\n  Result.unwrap!(Process.wait(p, 5000))")
             path #:exists 'truncate)
           (define file (path->string path))
           (check-equal? (cli "check" file) '(0 "check ok\n" ""))
           (define denied (cli "--json" file "--allow-run"))
           (check-equal? (car denied) 1)
           (check-equal? (hash-ref (string->jsexpr (caddr denied)) 'code) "RUNTIME-UNWRAP-ERROR")
           (check-equal? (cli "--allow-run" file "--allow-run")
                         '(0 "[]\n[\"--allow-run\"]\n" ""))
           (define help (cli "help" "Process.send" "--json"))
           (check-equal? (car help) 0)
           (check-equal? (hash-ref (string->jsexpr (cadr help)) 'result) "Result[Void]"))
         (lambda () (delete-file path))))

     (test-case "unavailable and malformed commands return errors without a child"
       (check-equal? (output
         "def main() -> Void\n  IO.inspect(Result.ok?(Process.spawn(\"agentica-nonexistent-command-5l\", [], 1000)))\n  IO.inspect(Result.ok?(Process.spawn(\"\", [], 1000)))\n  nul = Result.unwrap!(String.from_bytes([0]))\n  IO.inspect(Result.ok?(Process.spawn(\"node\", [nul], 1000)))\nend\n")
         "false\nfalse\nfalse\n"))

     (test-case "BDD capability reaches custom handlers and programs under test"
       (define directory (make-temporary-file "agentica-process-bdd~a" 'directory))
       (dynamic-wind void
         (lambda ()
           (define feature (build-path directory "process.feature"))
           (define steps (build-path directory "steps.agc"))
           (display-to-file
             "Feature: Process capability\nScenario: child\nGiven the Agentica program \"child.agc\"\nThen I receive a JSON line within 5000 milliseconds:\n  \"\"\"\n  [\"child\"]\n  \"\"\"\nAnd the program exits with code 0 within 5000 milliseconds\nScenario: handler\nThen the handler can spawn\n"
             feature)
           (display-to-file (program "args"
             "  puts(Result.unwrap!(Process.read_line(p, 5000)))\n  Result.unwrap!(Process.wait(p, 5000))"
             "" ", \"child\"") (build-path directory "child.agc"))
           (display-to-file
             (string-append "def handler(args: List[String]) -> Void\n" (spawn "args" ", \"handler\"")
               "  BDD.assert(Result.unwrap!(Process.read_line(p, 5000)) == \"[\\\"handler\\\"]\", \"argv\")\n  Result.unwrap!(Process.wait(p, 5000))\nend\ndef main() -> Void\n  BDD.step(\"the handler can spawn\", &handler)\nend\n") steps)
           (define args (list "test" (path->string feature) "--steps" (path->string steps) "--json"))
           (define denied (apply cli args))
           (check-equal? (car denied) 1)
           (check-equal? (hash-ref (string->jsexpr (cadr denied)) 'passed) 0)
           (define allowed (apply cli (append args '("--allow-run"))))
           (check-equal? (car allowed) 0)
           (check-equal? (hash-ref (string->jsexpr (cadr allowed)) 'passed) 2))
         (lambda () (delete-directory/files directory))))

     (test-case "cross-evaluation process access reports its own located diagnostic"
       (define p (evaluate
         (compile-program (string-append "def get() -> Process\n" (spawn "hold")
                                         "  return p\nend\ndef main() -> Void\nend\n"))
         #:entrypoint "get" #:allow-run #t))
       (define problem (evaluate
         (compile-program "def take(p: Process) -> Void\n  Process.close(p)\nend\ndef main() -> Void\nend\n")
         #:entrypoint "take" #:arguments (list p)))
       (check-equal? (diagnostic-code problem) 'RUNTIME-PROCESS-CONTEXT)
       (check-equal? (source-position-line (source-span-start (diagnostic-span problem))) 2))
     (test-case "permission, literal argv and inherited task capability"
       (define text (program "args" "  puts(Result.unwrap!(Process.read_line(p, 5000)))\n  IO.inspect(Process.wait(p, 5000))"
                             "" ", \"a b;$x\", \"--allow-run\""))
       (define-values (denied out err) (run text #:allowed? #f))
       (check-equal? (diagnostic-code denied) 'RUNTIME-UNWRAP-ERROR)
       (check-equal? out "")
       (check-equal? (output text) "[\"a b;$x\",\"--allow-run\"]\nok(0)\n"))

     (test-case "flushed text and bytes reply before stdin EOF; stderr stays separate"
       (check-equal?
        (output (program "echo"
          (string-append "  Result.unwrap!(Process.send(p, \"ñ\\n\", 5000))\n"
                         "  puts(Result.unwrap!(Process.read_line(p, 5000)))\n"
                         "  Result.unwrap!(Process.send_bytes(p, [0, 255, 10], 5000))\n"
                         "  IO.inspect(Process.read_bytes(p, 0, 5000))\n"
                         "  IO.inspect(Process.read_bytes(p, 3, 5000))\n"
                         "  IO.inspect(Process.close_stdin(p, 5000))\n"
                         "  IO.inspect(Process.close_stdin(p, 5000))\n"
                         "  IO.inspect(Result.ok?(Process.send(p, \"x\", 5000)))\n"
                         "  IO.inspect(Process.read_bytes(p, 3, 5000))\n"
                         "  IO.inspect(Process.wait(p, 5000))\n"
                         "  Process.close(p)\n  Process.close(p)\n"
                         "  IO.inspect(Result.ok?(Process.wait(p, 5000)))")) "peer stderr\n")
        "ñ\nok([])\nok([0, 255, 10])\nok()\nok()\nfalse\nok([])\nok(0)\nfalse\n"))

     (test-case "EOF, nonzero and repeated exit waits preserve unread output"
       (check-equal?
        (output (program "exit"
          "  IO.inspect(Process.wait(p, 5000))\n  IO.inspect(Process.wait(p, 5000))\n  puts(Result.unwrap!(Process.read_line(p, 5000)))\n  puts(Result.unwrap!(Process.read_line(p, 5000)))\n  IO.inspect(Result.ok?(Process.read_line(p, 5000)))"))
        "ok(7)\nok(7)\ndone\nlast\nfalse\n"))

     (test-case "invalid input preserves bytes; strict decoding consumes a complete bad line"
       (check-equal?
        (output (program "invalid"
          "  IO.inspect(Result.ok?(Process.read_bytes(p, -1, 1000)))\n  IO.inspect(Result.ok?(Process.read_bytes(p, 1048577, 1000)))\n  IO.inspect(Result.ok?(Process.read_line(p, 0)))\n  IO.inspect(Result.ok?(Process.read_line(p, 5000)))\n  puts(Result.unwrap!(Process.read_line(p, 5000)))"))
        "false\nfalse\nfalse\nfalse\nvalid\n")
       (check-equal?
        (output (program "echo"
          "  IO.inspect(Result.ok?(Process.send_bytes(p, [256], 1000)))\n  IO.inspect(Result.ok?(Process.send_bytes(p, List.append(List.repeat(65, 1048576), 65), 1000)))\n  Result.unwrap!(Process.send(p, \"valid\\n\", 5000))\n  puts(Result.unwrap!(Process.read_line(p, 5000)))") "peer stderr\n")
        "false\nfalse\nvalid\n"))

     (test-case "streaming exceeds 1 MiB with concurrent reads and independently drained stderr"
       (define drain
         "def drain(p: Process) -> Int\n  first = Result.unwrap!(Process.read_bytes(p, 1048576, 5000))\n  second = Result.unwrap!(Process.read_bytes(p, 1048576, 5000))\n  return List.size(first) + List.size(second)\nend\n")
       (check-equal? (output (program "flood"
         "  reader = Task.spawn(&drain, p)\n  IO.inspect(Process.wait(p, 5000))\n  IO.inspect(Task.await(reader))" drain))
         "ok(0)\n2097152\n")
       (define-values (result out err) (run (program "stderr" "  IO.inspect(Process.wait(p, 5000))")))
       (check-pred void? result)
       (check-equal? out "ok(0)\n")
       (check-equal? (string-length err) 2097152))

     (test-case "wait retries preserve children; active stream deadlines abort them"
       (check-equal? (output (program "release"
         "  pid = Result.unwrap!(Process.read_line(p, 5000))\n  reader = Task.spawn(&read, p)\n  Task.sleep(100)\n  IO.inspect(Result.ok?(Process.read_line(p, 20)))\n  Result.unwrap!(Process.send(p, \"exit\\n\", 5000))\n  IO.inspect(Result.ok?(Task.await(reader)))\n  IO.inspect(Process.wait(p, 5000))"
         "def read(p: Process) -> Result[String]\n  return Process.read_line(p, 5000)\nend\n"))
         "false\nfalse\nok(3)\n")
       (check-equal? (output (program "release"
         "  pid = Result.unwrap!(Process.read_line(p, 5000))\n  IO.inspect(Result.ok?(Process.wait(p, 20)))\n  Result.unwrap!(Process.send(p, \"exit\\n\", 5000))\n  IO.inspect(Process.wait(p, 5000))"))
         "false\nok(3)\n")
       (for ([operation (in-list
                         '("Process.read_line(p, 20)"
                           "Process.send_bytes(p, List.repeat(65, 1048576), 20)"))])
         (define-values (result out err)
           (run (program "hold" (format "  puts(Result.unwrap!(Process.read_line(p, 5000)))\n  IO.inspect(Result.ok?(~a))\n  IO.inspect(Result.ok?(Process.wait(p, 20)))" operation))))
         (check-pred void? result)
         (define lines (string-split out "\n"))
         (check-equal? (cdr lines) '("false" "false"))
         (check-false (alive? (car lines))))
       (check-equal? (output (program "oversized"
         "  IO.inspect(Result.ok?(Process.read_line(p, 5000)))\n  IO.inspect(Result.ok?(Process.wait(p, 1000)))"))
         "false\nfalse\n"))

     (test-case "evaluation outcomes kill and reap children"
       (for ([ending (in-list '("" "  System.exit(4)" "  x = 1 / 0"
                                "  while true\n  end"
                                "  task = Task.spawn(&crash, 0)\n  Task.sleep(60000)"))])
         (define-values (result out err)
           (run (program "hold" (string-append "  puts(Result.unwrap!(Process.read_line(p, 5000)))\n" ending)
                         "def crash(n: Int) -> Int\n  return 1 / 0\nend\n")
                #:limit (and (string-contains? ending "while") 100)))
         (check-regexp-match #px"^[0-9]+\n$" out)
         (when (string-contains? ending "crash")
           (check-equal? (diagnostic-code result) 'RUNTIME-DIVISION-BY-ZERO))
         (check-false (alive? out)))
       (define-values (input writer) (make-pipe))
       (define-values (reader output-port) (make-pipe))
       (define worker
         (thread (lambda ()
                   (evaluate (compile-program (program "hold"
                     "  puts(Result.unwrap!(Process.read_line(p, 5000)))\n  IO.flush()\n  s = IO.gets!()"))
                     #:in input #:out output-port #:allow-run #t))))
       (check-not-false (sync/timeout 5 reader))
       (define pid (read-line reader))
       (kill-thread worker)
       (let loop ([attempts 30])
         (when (and (positive? attempts) (alive? pid)) (sleep 0.05) (loop (sub1 attempts))))
       (check-false (alive? pid))
       (check-false (port-closed? output-port))
       (close-output-port output-port)
       (close-output-port writer)
       (close-input-port input)
       (close-input-port reader))]))
