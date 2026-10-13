#lang racket

(require rackunit json racket/runtime-path "cli-in-process.rkt")

(define-runtime-path stream-spec "bdd/specs/json-lines.feature")
(define-runtime-path main-file "../src/main.rkt")

(define (json-test #:before [before '()] . arguments)
  (define result (apply run-main-in-process (append before (list "test" "--json") arguments)))
  (check-equal? (caddr result) "")
  (string->jsexpr (cadr result)))

(define (with-suite files run)
  (define directory (normalize-path (make-temporary-directory "agentica-bdd-integration~a")))
  (dynamic-wind void
    (lambda ()
      (for ([entry (in-list files)])
        (display-to-file (cdr entry) (build-path directory (car entry))))
      (run directory))
    (lambda () (delete-directory/files directory))))

(define (in directory name)
  (path->string (build-path directory name)))

(define (cases report)
  (append-map (lambda (file) (hash-ref file 'scenarios)) (hash-ref report 'files)))

(define (codes report)
  (for/list ([item (in-list (cases report))])
    (define problem (hash-ref item 'error))
    (and (hash? problem) (hash-ref problem 'code))))

(define (gone? pid)
  (define deadline (+ (current-inexact-milliseconds) 5000))
  (let wait ()
    (define state
      (with-handlers ([exn:fail:filesystem? (lambda (_) #f)])
        (regexp-match #rx"^.*[)] (.)" (file->string (build-path "/proc" pid "stat")))))
    (cond
      [(or (not state) (equal? (cadr state) "Z")) #t]
      [(> (current-inexact-milliseconds) deadline) #f]
      [else (sleep 0.02) (wait)])))

(define (eventually? ready?)
  (define deadline (+ (current-inexact-milliseconds) 20000))
  (let wait ()
    (cond
      [(ready?) #t]
      [(> (current-inexact-milliseconds) deadline) #f]
      [else (sleep 0.05) (wait)])))

(define (command-lines-mention? text)
  (for/or ([entry (in-list (directory-list "/proc"))]
           #:when (regexp-match? #rx"^[0-9]+$" (path->string entry)))
    (define line
      (with-handlers ([exn:fail? (lambda (_) #"")])
        (file->bytes (build-path "/proc" entry "cmdline"))))
    (regexp-match? (regexp-quote (string->bytes/utf-8 text)) line)))

(define (start-cli arguments)
  (define executable (getenv "AGENTICA_TEST_EXECUTABLE"))
  (if executable
      (apply subprocess #f #f #f executable arguments)
      (apply subprocess #f #f #f (find-system-path 'exec-file) (path->string main-file) arguments)))

(define holder-program
  (string-append
   "def main() -> Void\n"
   "  p = Process.spawn(\"/bin/sh\", [\"-c\", \"echo $$ > pid.txt; echo started; exec sleep 60\"], 5000).unwrap!\n"
   "  started = Process.read_line(p, 5000).unwrap!\n  puts(\"ready\")\n  IO.flush()\n  line = IO.gets()\nend\n"))

(define (doc text)
  (string-append "  \"\"\"\n  " text "\n  \"\"\"\n"))

(module+ test
  (test-case "live JSON replies arrive before EOF and recover after errors"
    (define report (json-test (path->string stream-spec)))
    (check-true (hash-ref report 'ok) (~s report))
    (check-equal? (hash-ref report 'passed) 2))

  (test-case "a task receives while its handler sends, and a pending read fails its scenario"
    (with-suite
     `(("echo.agc" . "def main() -> Void\n  line = IO.gets!()\n  puts(line)\n  IO.flush()\n  ending = IO.gets()\nend\n")
       ("steps.agc" . ,(string-append
                        "import \"std/bdd\" as BDD\n\n"
                        "def receive(ctx: BDD.Context) -> BDD.Context\n  return BDD.then_line(ctx, \"hello\", 5000)\nend\n\n"
                        "def exchange(ctx: BDD.Context, args: List[String]) -> BDD.Context\n  task = Task.spawn(&receive, ctx)\n"
                        "  Task.sleep(0)\n  sent = BDD.when_line(ctx, \"hello\")\n  return Task.await(task)\nend\n\n"
                        "def wait(ctx: BDD.Context) -> BDD.Context\n  return BDD.then_line(ctx, \"never\", 5000)\nend\n\n"
                        "def pending(ctx: BDD.Context, args: List[String]) -> BDD.Context\n  task = Task.spawn(&wait, ctx)\n  Task.sleep(0)\n  return ctx\nend\n\n"
                        "def main() -> Void\n  BDD.run([BDD.step(\"exchange concurrently\", &exchange), BDD.step(\"leave a pending read\", &pending)])\nend\n"))
       ("tasks.feature" . ,(string-append
                            "Feature: Concurrent streams\nBackground:\nGiven the Agentica program \"echo.agc\"\n"
                            "Scenario: exchange\nThen exchange concurrently\nWhen I close stdin\nThen the program exits with code 0 within 5000 milliseconds\n"
                            "Scenario: pending\nThen leave a pending read\n"
                            "Scenario: later\nThen exchange concurrently\nWhen I close stdin\nThen the program exits with code 0 within 5000 milliseconds\n")))
     (lambda (directory)
       (define report (json-test (in directory "tasks.feature") "--steps" (in directory "steps.agc")))
       (check-equal? (codes report) '(#f "RUNTIME-BDD-PENDING-TASKS" #f)))))

  (test-case "a seed reaches step handlers and programs under test"
    (define draw "Random.int(1, 1000000).to_s + \" \" + Random.int(1, 1000000).to_s")
    (with-suite
     `(("draw.agc" . ,(format "def main() -> Void\n  puts(~a)\nend\n" draw))
       ("steps.agc" . ,(format (string-append "import \"std/bdd\" as BDD\n\ndef main() -> Void\n"
                                              "  BDD.run([BDD.step(\"stdout repeats the seeded draw\") do |ctx, args| BDD.then_stdout(ctx, ~a + \"\\n\") end])\nend\n")
                               draw))
       ("seed.feature" . ,(string-append "Feature: Seeds\nScenario: seeded\nGiven the Agentica program \"draw.agc\"\n"
                                         "Then the program exits with code 0 within 5000 milliseconds\nAnd stdout repeats the seeded draw\n")))
     (lambda (directory)
       (define arguments (list (in directory "seed.feature") "--steps" (in directory "steps.agc")))
       (check-true (hash-ref (apply json-test #:before '("--seed" "9") arguments) 'ok))
       (check-false (hash-ref (apply json-test arguments) 'ok)))))

  (test-case "programs under test: no flush, wrong output, the output limits, literal input and the working directory"
    (with-suite
     `(("buffered.agc" . "def main() -> Void\n  line = IO.gets!()\n  puts(line)\n  line = IO.gets!()\nend\n")
       ("output.agc" . "def main() -> Void\n  puts(\"actual\")\n  IO.warn(\"warning\")\n  System.exit(3)\nend\n")
       ("oversized.agc" . "def main() -> Void\n  puts(String.join(List.repeat(\"x\", 1048576), \"\"))\nend\n")
       ("flood.agc" . "def main() -> Void\n  IO.warn(String.join(List.repeat(\"x\", 1048576), \"\"))\n  line = IO.gets()\nend\n")
       ("where.agc" . "def main() -> Void\n  puts(Path.cwd().unwrap!)\nend\n")
       ("steps.agc" . ,(string-append
                        "import \"std/bdd\" as BDD\n\ndef main() -> Void\n"
                        "  BDD.run([BDD.step(\"the handler floods stdout\") do |ctx, args|\n"
                        "    puts(String.join(List.repeat(String.join(List.repeat(\"x\", 1000), \"\"), 1100), \"\\n\"))\n"
                        "    ctx\n  end])\nend\n"))
       ("lifecycle.feature" . "Feature: Lifecycle\n"))
     (lambda (directory)
       (display-to-file
        (string-append
         "Scenario: no flush\nGiven the Agentica program \"buffered.agc\"\n"
         "When I send the line \"hello\"\nThen I receive the line \"hello\" within 1000 milliseconds\n"
         "Scenario: wrong stdout\nGiven the Agentica program \"output.agc\"\n"
         "Then the program exits with code 3 within 5000 milliseconds\nAnd stdout is:\n" (doc "incorrect")
         "Scenario: wrong stderr\nGiven the Agentica program \"output.agc\"\n"
         "Then the program exits with code 3 within 5000 milliseconds\nAnd stderr is:\n" (doc "incorrect")
         "Scenario: wrong code\nGiven the Agentica program \"output.agc\"\nThen the program exits with code 0 within 5000 milliseconds\n"
         "Scenario: output limit\nGiven the Agentica program \"oversized.agc\"\nThen the program exits with code 0 within 5000 milliseconds\n"
         "Scenario: stderr flood\nGiven the Agentica program \"flood.agc\"\nThen I receive the line \"never\" within 5000 milliseconds\n"
         "Scenario: literal input and EOF\nGiven the Agentica program \"buffered.agc\"\nWhen I send input:\n" (doc "hello")
         "When I close stdin\nAnd I close stdin\nThen the program exits with code 1 within 5000 milliseconds\nAnd stdout is:\n" (doc "hello\n")
         "Scenario: working directory\nGiven the Agentica program \"where.agc\"\nThen I receive the line \"" (path->string (path->directory-path directory))
         "\" within 5000 milliseconds\n"
         "Scenario: later\nGiven the Agentica program \"output.agc\"\nThen the program exits with code 3 within 5000 milliseconds\n"
         "And stdout is:\n" (doc "actual\n") "And stderr is:\n" (doc "warning\n")
         "Scenario: handler flood\nGiven the handler floods stdout\n"
         "Scenario: step line over 1 MiB\nGiven the Agentica program \"output.agc\"\nWhen I send input:\n" (doc (make-string 600000 #\")))
        (build-path directory "lifecycle.feature") #:exists 'append)
       (define report (json-test (in directory "lifecycle.feature") "--steps" (in directory "steps.agc")))
       (check-equal? (codes report)
                     '("RUNTIME-BDD-TIMEOUT" "RUNTIME-BDD-ASSERTION" "RUNTIME-BDD-ASSERTION" "RUNTIME-BDD-ASSERTION"
                       "RUNTIME-BDD-OUTPUT-LIMIT" "RUNTIME-BDD-OUTPUT-LIMIT" #f #f #f
                       "RUNTIME-BDD-OUTPUT-LIMIT" "RUNTIME-BDD-IO"))
       (define (details item)
         (define problem (hash-ref item 'error))
         (list (hash-ref problem 'expected) (hash-ref problem 'actual)))
       (check-equal? (map details (list (second (cases report)) (fourth (cases report))))
                     '(("\"incorrect\"" "\"actual\\n\"") ("0" "3"))))))

  (test-case "a JSON line of a few hundred KB fits the step budget"
    (define items (make-list 30000 "abcdefghij"))
    (with-suite
     `(("big.agc" . "def main() -> Void\n  puts(JSON.encode(JSON.from(List.repeat(\"abcdefghij\", 30000))))\nend\n")
       ("big.feature" . ,(string-append "Feature: Big\nScenario: big line\nGiven the Agentica program \"big.agc\"\n"
                                        "Then I receive a JSON line within 5000 milliseconds:\n" (doc (jsexpr->string items)))))
     (lambda (directory)
       (check-true (hash-ref (json-test (in directory "big.feature")) 'ok)))))

  (test-case "a failed scenario leaves no process of its program behind"
    (with-suite
     `(("holder.agc" . ,holder-program)
       ("holder.feature" . ,(string-append "Feature: Cleanup\nScenario: held\nGiven the Agentica program \"holder.agc\"\n"
                                           "Then I receive the line \"ready\" within 5000 milliseconds\n"
                                           "And the program exits with code 0 within 200 milliseconds\n")))
     (lambda (directory)
       (define report (json-test "--allow-run" (in directory "holder.feature")))
       (check-equal? (codes report) '("RUNTIME-BDD-TIMEOUT"))
       (define pid (string-trim (file->string (build-path directory "pid.txt"))))
       (check-true (gone? pid) pid))))

  (test-case "killing the driver stops the runner, the scenario VM and the program, and a later run removes its folder"
    (with-suite
     `(("holder.agc" . ,holder-program)
       ("holder.feature" . ,(string-append "Feature: Killed\nScenario: held\nGiven the Agentica program \"holder.agc\"\n"
                                           "Then I receive the line \"ready\" within 5000 milliseconds\n"
                                           "And the program exits with code 0 within 20000 milliseconds\n")))
     (lambda (directory)
       (define temporary (build-path directory "tmp"))
       (make-directory temporary #o700)
       (define environment (environment-variables-copy (current-environment-variables)))
       (environment-variables-set! environment #"TMPDIR" (path->bytes temporary))
       (define-values (driver output input errors)
         (parameterize ([current-environment-variables environment])
           (start-cli (list "test" "--allow-run" (in directory "holder.feature")))))
       (close-output-port input)
       (define pid-file (build-path directory "pid.txt"))
       (check-true (eventually? (lambda () (and (file-exists? pid-file) (regexp-match? #rx"[0-9]" (file->string pid-file))))))
       (subprocess-kill driver #t)
       (subprocess-wait driver)
       (close-input-port output)
       (close-input-port errors)
       (define pid (string-trim (file->string pid-file)))
       (check-true (gone? pid) pid)
       (check-true (eventually? (lambda () (not (command-lines-mention? (path->string temporary))))))
       (check-equal? (length (directory-list temporary)) 1)
       (define live (build-path temporary "agentica-bdd-0123456789abcdef"))
       (make-directory live)
       (define held (open-output-file (build-path live "lock")))
       (check-true (port-try-file-lock? held 'exclusive))
       (define outside (build-path directory "outside"))
       (make-directory outside)
       (display-to-file "keep" (build-path outside "lock"))
       (make-file-or-directory-link outside (build-path temporary "agentica-bdd-fedcba9876543210"))
       (make-directory (build-path temporary "agentica-bdd-00ff"))
       (define-values (later later-output later-input later-errors)
         (parameterize ([current-environment-variables environment])
           (start-cli (list "test" (in directory "missing.feature")))))
       (close-output-port later-input)
       (port->string later-output)
       (port->string later-errors)
       (subprocess-wait later)
       (close-input-port later-output)
       (close-input-port later-errors)
       (close-output-port held)
       (check-equal? (map path->string (directory-list temporary))
                     '("agentica-bdd-00ff" "agentica-bdd-0123456789abcdef" "agentica-bdd-fedcba9876543210"))
       (check-equal? (file->string (build-path outside "lock")) "keep"))))

  (test-case "a temporary directory others can write to without the sticky bit is refused"
    (with-suite
     '()
     (lambda (directory)
       (define temporary (build-path directory "shared"))
       (make-directory temporary)
       (define environment (environment-variables-copy (current-environment-variables)))
       (environment-variables-set! environment #"TMPDIR" (path->bytes temporary))
       (define (status-and-code)
         (define-values (process output input errors)
           (parameterize ([current-environment-variables environment])
             (start-cli (list "test" "--json" (path->string directory)))))
         (close-output-port input)
         (define drained (thread (lambda () (port->string errors))))
         (define report (string->jsexpr (port->string output)))
         (thread-wait drained)
         (close-input-port output)
         (close-input-port errors)
         (subprocess-wait process)
         (list (subprocess-status process) (hash-ref (hash-ref (car (hash-ref report 'files)) 'error) 'code)))
       (file-or-directory-permissions temporary #o777)
       (check-equal? (status-and-code) '(2 "RUNTIME-BDD-INFRA"))
       (file-or-directory-permissions temporary #o1777)
       (check-equal? (status-and-code) '(1 "CHECK-BDD-EMPTY"))
       (file-or-directory-permissions temporary #o775)
       (check-equal? (status-and-code) '(1 "CHECK-BDD-EMPTY"))
       (file-or-directory-permissions temporary #o2775)
       (check-equal? (status-and-code) '(2 "RUNTIME-BDD-INFRA"))))))
