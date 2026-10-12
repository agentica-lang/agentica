#lang racket

(require rackunit json racket/runtime-path "../src/bdd-runner.rkt" (only-in "cli-in-process.rkt" fallback-notice?))

(define-runtime-path handlers "bdd/handlers.agc")
(define-runtime-path custom "bdd/specs/custom.feature")
(define-runtime-path main-file "../src/main.rkt")

(define (cases report)
  (append-map (lambda (file) (hash-ref file 'scenarios)) (hash-ref report 'files)))

(define (cli . arguments)
  (define-values (process output input errors)
    (apply subprocess #f #f #f (find-system-path 'exec-file) main-file arguments))
  (close-output-port input)
  (define text (port->string output))
  (define error-text (port->string errors))
  (subprocess-wait process)
  (close-input-port output)
  (close-input-port errors)
  (list (subprocess-status process) text error-text))

(module+ test
  (test-case "concurrent handlers preserve state, reject pending tasks and continue after failures"
    (define directory (make-temporary-file "agentica-bdd-task~a" 'directory))
    (dynamic-wind void
      (lambda ()
        (define feature-path (build-path directory "tasks.feature"))
        (define step-path (build-path directory "steps.agc"))
        (display-to-file
         (string-append "Feature: Tasks\nScenario: parallel\nThen state is concurrent\n"
                        "Scenario: pending\nThen tasks are pending\n"
                        "Scenario: failure\nThen a task crashes\n"
                        "Scenario: later\nThen later works\n") feature-path)
        (display-to-file
         (string-append
          "def worker(n: Int) -> Void\n  Task.sleep(0)\n  key = String.from_int(n)\n"
          "  BDD.set(key, Result.unwrap!(JSON.parse(key)))\n  BDD.assert(n > 0, \"worker\")\nend\n\n"
          "\ndef parallel(args: List[String]) -> Void\n  tasks: List[Task[Void]] = []\n"
          "  for n in [1, 2, 3, 4]\n    tasks = List.append(tasks, Task.spawn(&worker, n))\n  end\n"
          "  for task in tasks\n    Task.await(task)\n  end\n"
          "  for n in [1, 2, 3, 4]\n    BDD.assert(Result.ok?(BDD.get(String.from_int(n))), \"state lost\")\n  end\nend\n\n"
          "\ndef wait(n: Int) -> Void\n  Task.sleep(60000)\nend\n\n"
          "\ndef pending(args: List[String]) -> Void\n  task = Task.spawn(&wait, 0)\nend\n\n"
          "\ndef crash(n: Int) -> Int\n  return 1 / 0\nend\n\n"
          "\ndef broken(args: List[String]) -> Void\n  task = Task.spawn(&crash, 0)\n  Task.sleep(60000)\nend\n\n"
          "\ndef good(args: List[String]) -> Void\n  BDD.assert(not Result.ok?(BDD.get(\"1\")), \"state leaked\")\nend\n\n"
          "\ndef register_a(n: Int) -> Void\n  BDD.step(\"state is concurrent\", &parallel)\n  BDD.step(\"tasks are pending\", &pending)\nend\n\n"
          "\ndef register_b(n: Int) -> Void\n  BDD.step(\"a task crashes\", &broken)\n  BDD.step(\"later works\", &good)\nend\n\n"
          "\ndef main() -> Void\n  a = Task.spawn(&register_a, 0)\n  b = Task.spawn(&register_b, 0)\n  Task.await(a)\n  Task.await(b)\nend\n\n") step-path)
        (define report (run-bdd (list feature-path) #:steps (list step-path)))
        (check-equal? (hash-ref report 'passed) 2)
        (check-equal? (hash-ref report 'failed) 2)
        (define results (cases report))
        (check-equal? (hash-ref (hash-ref (cadr results) 'error) 'code) "RUNTIME-BDD-PENDING-TASKS")
        (check-equal? (hash-ref (hash-ref (caddr results) 'error) 'code) "RUNTIME-DIVISION-BY-ZERO")
        (display-to-file
         (string-append "def good(args: List[String]) -> Void\n  BDD.assert(true, \"ok\")\nend\n\n"
                        "\ndef register(name: String) -> Void\n  BDD.step(name, &good)\nend\n\n"
                        "\ndef main() -> Void\n  a = Task.spawn(&register, \"duplicate\")\n"
                        "  b = Task.spawn(&register, \"duplicate\")\n  Task.await(a)\n  Task.await(b)\nend\n\n")
         step-path #:exists 'truncate)
        (define duplicate (run-bdd (list feature-path) #:steps (list step-path)))
        (check-equal? (hash-ref (hash-ref (car (hash-ref duplicate 'files)) 'error) 'code) "RUNTIME-BDD-DUPLICATE"))
      (lambda () (delete-directory/files directory))))

  (test-case "steps registered with blocks run with captured values"
    (define directory (make-temporary-file "agentica-bdd-block~a" 'directory))
    (dynamic-wind void
      (lambda ()
        (define feature-path (build-path directory "blocks.feature"))
        (define step-path (build-path directory "steps.agc"))
        (display-to-file "Feature: Blocks\nScenario: good\nThen 3 is small\nScenario: bad\nThen 9 is small\n"
                         feature-path)
        (display-to-file
         (string-append "def main() -> Void\n  limit = 5\n"
                        "  BDD.step(\"{int} is small\") do |args|\n"
                        "    BDD.assert(args[0].to_i! < limit, \"too big\")\n  end\nend\n\n")
         step-path)
        (define report (run-bdd (list feature-path) #:steps (list step-path)))
        (check-equal? (hash-ref report 'passed) 1)
        (check-equal? (hash-ref report 'failed) 1))
      (lambda () (delete-directory/files directory))))

  (test-case "custom handlers receive arguments and share only scenario-local state"
    (define report (run-bdd (list custom (build-path (path-only custom) "." "custom.feature")) #:steps (list handlers)))
    (check-true (hash-ref report 'ok))
    (check-equal? (hash-ref report 'passed) 4)
    (check-equal? (map (lambda (item) (hash-ref item 'name)) (cases report))
                  '("Remember 7" "Remember -3" "Doc String and Data Table" "Quoted capture")))

  (test-case "failures, missing checks and premature exits never stop remaining scenarios"
    (define directory (make-temporary-file "agentica-bdd-test~a" 'directory))
    (dynamic-wind void
      (lambda ()
        (display-to-file "Feature: invalid\nScenario: empty\n" (build-path directory "a.feature"))
        (display-to-file
          (string-append
           "Feature: Failures\nScenario: assertion\nThen an assertion fails\nAnd scenario state is empty\n"
           "Scenario: no checks\nThen scenario state is empty\nAnd nothing is checked\n"
           "Scenario: runtime\nThen execution crashes\n"
           "Scenario: premature\nThen execution exits\n"
           "Scenario: budget\nThen execution loops\n"
           "Scenario: unknown\nGiven the Agentica program \"missing.agc\"\nThen missing definition\n"
           "Scenario: later\nThen scenario state is empty\n") (build-path directory "b.feature"))
        (display-to-file "Feature: Last\nScenario: last\nThen scenario state is empty\n" (build-path directory "c.feature"))
        (define report (run-bdd (list directory) #:steps (list handlers)))
        (check-false (hash-ref report 'ok))
        (check-equal? (hash-ref report 'exit_code) 1)
        (check-equal? (hash-ref report 'file_errors) 1)
        (check-equal? (hash-ref report 'passed) 2)
        (check-equal? (hash-ref report 'failed) 6)
        (define results (cases report))
        (check-equal? (map (lambda (item) (hash-ref (hash-ref item 'error) 'code)) (take results 6))
                      '("RUNTIME-BDD-ASSERTION" "RUNTIME-BDD-NO-ASSERTION" "RUNTIME-DIVISION-BY-ZERO"
                        "RUNTIME-BDD-PREMATURE-EXIT" "RUNTIME-STEP-LIMIT" "CHECK-BDD-UNDEFINED"))
        (check-equal? (hash-ref (cadr (hash-ref (car results) 'steps)) 'status) "not_executed")
        (check-equal? (hash-ref (car (hash-ref (list-ref results 5) 'steps)) 'status) "not_executed"))
      (lambda () (delete-directory/files directory))))

  (test-case "invalid registrations and ambiguous patterns fail explicitly"
    (define directory (make-temporary-file "agentica-bdd-pattern~a" 'directory))
    (dynamic-wind void
      (lambda ()
        (define feature-path (build-path directory "case.feature"))
        (define step-path (build-path directory "steps.agc"))
        (display-to-file "Feature: Patterns\nScenario: ambiguous\nThen value is 1\n" feature-path)
        (display-to-file
         "def assert(args: List[String]) -> Void\n  BDD.assert(true, \"valid\")\nend\n\ndef main() -> Void\n  BDD.step(\"value is {int}\", &assert)\n  BDD.step(\"value is 1\", &assert)\nend\n\n" step-path)
        (define ambiguous (run-bdd (list feature-path) #:steps (list step-path)))
        (check-equal? (hash-ref (hash-ref (car (cases ambiguous)) 'error) 'code) "CHECK-BDD-AMBIGUOUS")
        (for ([entry '(("BDD.step(\"x\", &assert)\n  BDD.step(\"x\", &assert)" "RUNTIME-BDD-DUPLICATE")
                       ("BDD.step(\"x {float}\", &assert)" "RUNTIME-BDD-PATTERN")
                       ("BDD.step(\"x\", &main)" "CHECK-TYPE-MISMATCH"))])
          (display-to-file (format "def assert(args: List[String]) -> Void\n  BDD.assert(true, \"valid\")\nend\n\ndef main() -> Void\n  ~a\nend\n\n" (car entry)) step-path #:exists 'truncate)
          (define report (run-bdd (list custom) #:steps (list step-path handlers)))
          (check-equal? (hash-ref (hash-ref (car (hash-ref report 'files)) 'error) 'code) (cadr entry))
          (check-equal? (hash-ref report 'passed) 4)))
      (lambda () (delete-directory/files directory))))

  (test-case "CLI and builtin expose the same verdict without leaking handler output"
    (define directory (make-temporary-file "agentica-bdd-cli~a" 'directory))
    (dynamic-wind void
      (lambda ()
        (define result (cli "test" (path->string custom) "--steps" (path->string handlers) "--json"))
        (check-equal? (car result) 0)
        (check-equal? (caddr result) "")
        (define report (string->jsexpr (cadr result)))
        (check-true (hash-ref report 'ok))
        (check-equal? (hash-ref report 'passed) 4)
        (for ([option '("--steps" "--unknown")])
          (define invalid (cli "test" "--json" option))
          (check-equal? (car invalid) 2)
          (check-equal? (caddr invalid) "")
          (check-equal? (hash-ref (string->jsexpr (cadr invalid)) 'exit_code) 2))
        (define driver (build-path directory "run.agc"))
        (display-to-file (format "def main() -> Void\n  report = Result.unwrap!(BDD.run(~s, [~s]))\n  puts(JSON.encode(report))\nend\n\n"
                                 (path->string custom) (path->string handlers)) driver)
        (define builtin (cli (path->string driver)))
        (check-equal? (car builtin) 0)
        (check-true (fallback-notice? (caddr builtin) "BDD.run") (caddr builtin))
        (check-equal? (hash-ref (string->jsexpr (cadr builtin)) 'passed) 4)
        (for ([style '("--ai" "plain")])
          (define text (apply cli (append (if (equal? style "plain") '() (list style))
                                         (list "test" (path->string custom) "--steps" (path->string handlers)))))
          (check-equal? (car text) 0)
          (check-regexp-match #rx"4 passed, 0 failed" (cadr text)))
        (define empty (cli "test" (path->string directory) "--json"))
        (check-equal? (car empty) 1)
        (check-false (hash-ref (string->jsexpr (cadr empty)) 'ok))
        (check-equal? (hash-ref (string->jsexpr (cadr empty)) 'file_errors) 1)
        (define failure-file (build-path directory "failure.feature"))
        (display-to-file "Feature: failure\nScenario: fail\nThen an assertion fails\n" failure-file)
        (display-to-file (format "def main() -> Void\n  result = BDD.run(~s, [~s])\n  IO.inspect(Result.ok?(result))\n  report = Result.unwrap!(result)\n  IO.inspect(Result.unwrap!(JSON.bool(Result.unwrap!(JSON.get(report, \"ok\")))))\nend\n\n"
                                 (path->string failure-file) (path->string handlers)) driver #:exists 'truncate)
        (check-equal? (cli "--legacy-eval" (path->string driver)) '(0 "true\nfalse\n" "")))
      (lambda () (delete-directory/files directory)))))
