#lang racket

(require (except-in rackunit check) racket/runtime-path racket/system json)

(define-runtime-path peer "fixtures/process-peer.js")
(define-runtime-path main-file "../src/main.rkt")
(define node (find-executable-path "node"))

(for ([name '(#"AGENTICA_VM_TRACE" #"AGENTICA_VM_TRACE_FILE" #"AGENTICA_FLUSH_TIMEOUT_MS")])
  (environment-variables-set! (current-environment-variables) name #f))

(define (spawn mode [extra ""])
  (format "  p = Result.unwrap!(Process.spawn(~s, [~s, ~s~a], 5000))\n"
          (path->string node) (path->string peer) mode extra))

(define (captured mode body [prefix ""])
  (format "~adef main() -> Void\n  p = Result.unwrap!(Process.spawn_captured(~s, [~s, ~s], \".\", 5000))\n~a\nend\n\n"
          prefix (path->string node) (path->string peer) mode body))

(define (probe pid)
  (format "Process.wait(Result.unwrap!(Process.spawn(~s, [~s, \"probe\", ~a], 5000)), 5000)"
          (path->string node) (path->string peer) pid))

(define (program mode body [prefix ""] [extra ""])
  (string-append prefix "def main() -> Void\n" (spawn mode extra) body "\nend\n\n"))

(define (run text #:allowed? [allowed? #t] #:limit [limit #f])
  (define file (make-temporary-file "agentica-process~a.agc"))
  (dynamic-wind
    void
    (lambda ()
      (display-to-file text file #:exists 'truncate)
      (match-define (list status out err)
        (apply cli (append (if allowed? '("--allow-run") '()) '("--json")
                           (if limit (list "--max-steps" (number->string limit)) '())
                           (list (path->string file)))))
      (define lines (string-split err "\n"))
      (define problem
        (and (pair? lines) (with-handlers ([exn:fail? (lambda (_) #f)]) (string->jsexpr (last lines)))))
      (cond
        [(zero? status) (values (void) out err)]
        [(hash? problem) (values (string->symbol (hash-ref problem 'code)) out
                                 (string-join (drop-right lines 1) "\n"))]
        [else (values status out err)]))
    (lambda () (delete-file file))))

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
      (define errors #f)
      (define reader (thread (lambda () (set! errors (port->string err)))))
      (define text (port->string out))
      (thread-wait reader)
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
         "def main() -> Void\n  IO.inspect(Result.ok?(Process.spawn(\"agentica-nonexistent-command-5l\", [], 1000)))\n  IO.inspect(Result.ok?(Process.spawn(\"\", [], 1000)))\n  nul = Result.unwrap!(String.from_bytes([0]))\n  IO.inspect(Result.ok?(Process.spawn(\"node\", [nul], 1000)))\nend\n\n")
         "false\nfalse\nfalse\n"))

     (test-case "BDD handlers can always spawn and programs under test need --allow-run"
       (define directory (make-temporary-file "agentica-process-bdd~a" 'directory))
       (dynamic-wind void
         (lambda ()
           (define feature (build-path directory "process.feature"))
           (define steps (build-path directory "steps.agc"))
           (display-to-file
             "Feature: Process capability\nScenario: child\nGiven the Agentica program \"child.agc\"\nThen I receive a JSON line within 30000 milliseconds:\n  \"\"\"\n  [\"child\"]\n  \"\"\"\nAnd the program exits with code 0 within 30000 milliseconds\nScenario: handler\nThen the handler can spawn\n"
             feature)
           (display-to-file (program "args"
             "  puts(Result.unwrap!(Process.read_line(p, 5000)))\n  Result.unwrap!(Process.wait(p, 5000))"
             "" ", \"child\"") (build-path directory "child.agc"))
           (display-to-file
             (string-append "import \"std/bdd\" as BDD\n\ndef handler(ctx: BDD.Context, args: List[String]) -> BDD.Context\n"
               (spawn "args" ", \"handler\"")
               "  checked = BDD.assert(ctx, Result.unwrap!(Process.read_line(p, 5000)) == \"[\\\"handler\\\"]\", \"argv\")\n"
               "  Result.unwrap!(Process.wait(p, 5000))\n  return checked\nend\n\n"
               "def main() -> Void\n  BDD.run([BDD.step(\"the handler can spawn\", &handler)])\nend\n") steps)
           (define args (list "test" (path->string feature) "--steps" (path->string steps) "--json"))
           (define denied (apply cli args))
           (check-equal? (car denied) 1)
           (define report (string->jsexpr (cadr denied)))
           (check-equal? (hash-ref report 'passed) 1)
           (check-equal? (map (lambda (item) (hash-ref item 'status))
                              (hash-ref (car (hash-ref report 'files)) 'scenarios))
                         '("failed" "passed"))
           (define allowed (apply cli (append args '("--allow-run"))))
           (check-equal? (car allowed) 0)
           (check-equal? (hash-ref (string->jsexpr (cadr allowed)) 'passed) 2))
         (lambda () (delete-directory/files directory))))

     (test-case "permission, literal argv and inherited task capability"
       (define text (program "args" "  puts(Result.unwrap!(Process.read_line(p, 5000)))\n  IO.inspect(Process.wait(p, 5000))"
                             "" ", \"a b;$x\", \"--allow-run\""))
       (define-values (denied out err) (run text #:allowed? #f))
       (check-equal? denied 'RUNTIME-UNWRAP-ERROR)
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
         "def drain(p: Process) -> Int\n  first = Result.unwrap!(Process.read_bytes(p, 1048576, 5000))\n  second = Result.unwrap!(Process.read_bytes(p, 1048576, 5000))\n  return List.size(first) + List.size(second)\nend\n\n")
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
         "def read(p: Process) -> Result[String]\n  return Process.read_line(p, 5000)\nend\n\n"))
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

     (test-case "every way a run ends kills and reaps its children"
       (for ([ending (in-list '("" "  System.exit(4)" "  x = 1 / 0"
                                "  while true\n  end"
                                "  task = Task.spawn(&crash, 0)\n  n = Task.await(task)"))])
         (define-values (result out err)
           (run (program "hold" (string-append "  puts(Result.unwrap!(Process.read_line(p, 5000)))\n" ending)
                         "def crash(n: Int) -> Int\n  return 1 / 0\nend\n\n")
                #:limit (and (string-contains? ending "while") 100)))
         (check-regexp-match #px"^[0-9]+\n$" out)
         (when (string-contains? ending "crash")
           (check-equal? result 'RUNTIME-TASK-CRASHED))
         (check-false (alive? out)))
       (define-values (result out err)
         (run (captured "stubborn" "  puts(Result.unwrap!(Process.read_line(p, 5000)))")))
       (check-pred void? result)
       (check-regexp-match #px"^[0-9]+\n$" out)
       (check-false (alive? out)))

     (test-case "closing a plain child returns only after it is gone, even when it ignores SIGTERM"
       (check-equal? (output (program "stubborn"
         (string-append "  pid = Result.unwrap!(Process.read_line(p, 5000))\n"
                        "  Process.close(p)\n  IO.inspect(" (probe "pid") ")")))
         "ok(1)\n"))]))
