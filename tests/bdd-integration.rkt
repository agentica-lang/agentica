#lang racket

(require rackunit racket/runtime-path
         "../src/bdd.rkt" "../src/bdd-runner.rkt" "../src/diagnostic.rkt" "../src/source.rkt")

(define-runtime-path stream-spec "bdd/specs/json-lines.feature")

(module+ test
    (test-case "BDD tasks receive while sending and clean up pending tasks"
      (define directory (make-temporary-file "agentica-bdd-concurrent~a" 'directory))
      (dynamic-wind void
        (lambda ()
          (display-to-file
           "def main() -> Void\n  line = IO.gets!()\n  puts(line)\n  IO.flush()\n  ending = IO.gets()\nend\n"
           (build-path directory "echo.agc"))
          (define steps (build-path directory "steps.agc"))
          (display-to-file
           (string-append
            "def receive(n: Int) -> Void\n  BDD.then_line(\"hello\", 5000)\nend\n"
            "def exchange(args: List[String]) -> Void\n  task = Task.spawn(&receive, 0)\n"
            "  Task.sleep(0)\n  BDD.when_line(\"hello\")\n  Task.await(task)\nend\n"
            "def wait(n: Int) -> Void\n  BDD.then_line(\"never\", 5000)\nend\n"
            "def pending(args: List[String]) -> Void\n  task = Task.spawn(&wait, 0)\n  Task.sleep(0)\nend\n"
            "def main() -> Void\n  BDD.step(\"exchange concurrently\", &exchange)\n  BDD.step(\"leave a pending read\", &pending)\nend\n") steps)
          (display-to-file
           (string-append "Feature: Concurrent streams\nBackground:\nGiven the Agentica program \"echo.agc\"\n"
                          "Scenario: exchange\nThen exchange concurrently\nWhen I close stdin\nThen the program exits with code 0 within 5000 milliseconds\n"
                          "Scenario: pending\nThen leave a pending read\n"
                          "Scenario: later\nThen exchange concurrently\nWhen I close stdin\nThen the program exits with code 0 within 5000 milliseconds\n")
           (build-path directory "tasks.feature"))
          (define report (run-bdd (list directory) #:steps (list steps)))
          (check-equal? (hash-ref report 'passed) 2 (format "~s" report))
          (check-equal? (hash-ref report 'failed) 1)
          (define results (hash-ref (car (hash-ref report 'files)) 'scenarios))
          (check-equal? (hash-ref (hash-ref (cadr results) 'error) 'code) "RUNTIME-BDD-PENDING-TASKS"))
        (lambda () (delete-directory/files directory))))

    (test-case "a seed reaches step handlers and programs under test"
      (define directory (make-temporary-file "agentica-bdd-seed~a" 'directory))
      (dynamic-wind void
        (lambda ()
          (define draw "String.from_int(Random.int(1, 1000000)) + \" \" + String.from_int(Random.int(1, 1000000))")
          (display-to-file (format "def main() -> Void\n  puts(~a)\nend\n" draw)
                           (build-path directory "draw.agc"))
          (define steps (build-path directory "steps.agc"))
          (display-to-file
           (string-append
            (format "def same(args: List[String]) -> Void\n  BDD.then_stdout(~a + \"\\n\")\nend\n" draw)
            "def main() -> Void\n  BDD.step(\"stdout repeats the seeded draw\", &same)\nend\n")
           steps)
          (display-to-file
           (string-append "Feature: Seeds\nScenario: seeded\nGiven the Agentica program \"draw.agc\"\n"
                          "Then the program exits with code 0 within 5000 milliseconds\n"
                          "And stdout repeats the seeded draw\n")
           (build-path directory "seed.feature"))
          (check-true (hash-ref (run-bdd (list directory) #:steps (list steps) #:seed 9) 'ok))
          (check-false (hash-ref (run-bdd (list directory) #:steps (list steps)) 'ok)))
        (lambda () (delete-directory/files directory))))

    (test-case "live JSON responses arrive before EOF and recover after errors"
      (define report (run-bdd (list stream-spec)))
      (check-true (hash-ref report 'ok) (format "~s" report))
      (check-equal? (hash-ref report 'passed) 2))

    (test-case "unflushed output times out, wrong output fails and later scenarios run"
      (define directory (make-temporary-file "agentica-bdd-integration~a" 'directory))
      (dynamic-wind void
        (lambda ()
          (display-to-file "def main() -> Void\n  line = IO.gets!()\n  puts(line)\n  line = IO.gets!()\nend\n" (build-path directory "buffered.agc"))
          (display-to-file "def main() -> Void\n  puts(\"actual\")\n  IO.warn(\"warning\")\n  System.exit(3)\nend\n" (build-path directory "output.agc"))
          (display-to-file "def main() -> Void\n  puts(String.join(List.repeat(\"x\", 1048576), \"\"))\nend\n" (build-path directory "oversized.agc"))
          (display-to-file
           (string-append
            "Feature: Lifecycle\nScenario: no flush\nGiven the Agentica program \"buffered.agc\"\n"
            "When I send the line \"hello\"\nThen I receive the line \"hello\" within 1000 milliseconds\n"
            "Scenario: wrong stdout\nGiven the Agentica program \"output.agc\"\n"
            "Then the program exits with code 3 within 5000 milliseconds\nAnd stdout is:\n  \"\"\"\n  incorrect\n  \"\"\"\n"
            "Scenario: wrong stderr\nGiven the Agentica program \"output.agc\"\n"
            "Then the program exits with code 3 within 5000 milliseconds\nAnd stderr is:\n  \"\"\"\n  incorrect\n  \"\"\"\n"
            "Scenario: wrong code\nGiven the Agentica program \"output.agc\"\nThen the program exits with code 0 within 5000 milliseconds\n"
            "Scenario: output limit\nGiven the Agentica program \"oversized.agc\"\nThen the program exits with code 0 within 5000 milliseconds\n"
            "Scenario: literal input and EOF\nGiven the Agentica program \"buffered.agc\"\nWhen I send input:\n  \"\"\"\n  hello\n  \"\"\"\nWhen I close stdin\nThen the program exits with code 1 within 5000 milliseconds\nAnd stdout is:\n  \"\"\"\n  hello\n\n  \"\"\"\n"
            "Scenario: later\nGiven the Agentica program \"output.agc\"\nThen the program exits with code 3 within 5000 milliseconds\n"
            "And stdout is:\n  \"\"\"\n  actual\n\n  \"\"\"\nAnd stderr is:\n  \"\"\"\n  warning\n\n  \"\"\"\n")
           (build-path directory "lifecycle.feature"))
          (define report (run-bdd (list directory)))
          (check-equal? (hash-ref report 'passed) 2 (format "~s" report))
          (check-equal? (hash-ref report 'failed) 5)
          (define results (hash-ref (car (hash-ref report 'files)) 'scenarios))
          (check-equal? (hash-ref (hash-ref (car results) 'error) 'code) "RUNTIME-BDD-TIMEOUT")
          (for ([item (in-list (take (cdr results) 3))])
            (check-equal? (hash-ref (hash-ref item 'error) 'code) "RUNTIME-BDD-ASSERTION"))
          (check-equal? (hash-ref (hash-ref (list-ref results 4) 'error) 'code) "RUNTIME-BDD-OUTPUT-LIMIT"))
        (lambda () (delete-directory/files directory))))

    (test-case "scenario cleanup terminates a blocked native process"
      (define directory (make-temporary-file "agentica-bdd-cleanup~a" 'directory))
      (define context (make-bdd-context directory))
      (define span (source-span (source "cleanup.feature" "") (source-position 0 1 1) (source-position 0 1 1)))
      (dynamic-wind void
        (lambda ()
          (display-to-file "def main() -> Void\n  line = IO.gets!()\nend\n" (build-path directory "blocked.agc"))
          (check-equal? (bdd-call context "BDD.given_program" '("blocked.agc") span) (void))
          (define processes
            (filter subprocess? (custodian-managed-list (bdd-context-custodian context) (current-custodian))))
          (check-equal? (length processes) 1)
          (define process (car processes))
          (check-equal? (subprocess-status process) 'running)
          (bdd-cleanup! context)
          (check-true (exact-integer? (subprocess-status process))))
        (lambda () (bdd-cleanup! context) (delete-directory/files directory)))))
