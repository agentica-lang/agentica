#lang racket

(require rackunit json racket/runtime-path "cli-in-process.rkt")

(define-runtime-path handlers "bdd/handlers.agc")
(define-runtime-path custom "bdd/specs/custom.feature")

(define (agentica-test #:environment [environment (current-environment-variables)] . arguments)
  (apply run-main-in-process #:environment environment "test" arguments))

(define (json-test . arguments)
  (define result (apply agentica-test "--json" arguments))
  (check-equal? (caddr result) "")
  (list (car result) (string->jsexpr (cadr result))))

(define (with-suite files run)
  (define directory (make-temporary-directory "agentica-bdd~a"))
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

(define (code-of item)
  (hash-ref (hash-ref item 'error) 'code))

(define (file-error report)
  (hash-ref (car (hash-ref report 'files)) 'error))

(define (start-line problem)
  (hash-ref (hash-ref (hash-ref problem 'range) 'start) 'line))

(define (steps-program . parts)
  (string-append "import \"std/bdd\" as BDD\n\n" (string-join parts "\n") "\n"))

(define (main-running . steps)
  (format "def main() -> Void\n  BDD.run([\n~a\n  ])\nend\n"
          (string-join (map (lambda (step) (string-append "    " step)) steps) ",\n")))

(module+ test
  (test-case "the custom suite passes in the three formats, with outline names and quiet handlers"
    (match-define (list status report)
      (json-test (path->string custom) (path->string custom) "--steps" (path->string handlers)))
    (check-equal? status 0)
    (check-true (hash-ref report 'ok))
    (check-equal? (hash-ref report 'passed) 4)
    (check-equal? (map (lambda (item) (hash-ref item 'name)) (cases report))
                  '("Remember 7" "Remember -3" "Doc String and Data Table" "Quoted capture"))
    (for ([style '(() ("--ai"))])
      (define result (apply agentica-test (append style (list (path->string custom) "--steps" (path->string handlers)))))
      (check-equal? (car result) 0)
      (check-equal? (caddr result) "")
      (check-equal? (cadr result)
                    (string-append "PASS Custom Agentica steps / Remember 7\nPASS Custom Agentica steps / Remember -3\n"
                                   "PASS Custom Agentica steps / Doc String and Data Table\n"
                                   "PASS Custom Agentica steps / Quoted capture\n"
                                   "4 passed, 0 failed, 0 not executed, 0 file errors\n"))))

  (test-case "a failing, crashing, exiting or looping handler fails only its scenario"
    (with-suite
     `(("a.feature" . "Feature: invalid\nScenario: empty\n")
       ("b.feature" . ,(string-append
                        "Feature: Failures\nScenario: assertion\nThen an assertion fails\nAnd scenario state is empty\n"
                        "Scenario: no checks\nThen scenario state is empty\nAnd nothing is checked\n"
                        "Scenario: runtime\nThen execution crashes\n"
                        "Scenario: premature\nThen execution exits\n"
                        "Scenario: budget\nThen execution loops\n"
                        "Scenario: unknown\nGiven the Agentica program \"missing.agc\"\nThen missing definition\n"
                        "Scenario: later\nThen scenario state is empty\n"))
       ("c.feature" . "Feature: Last\nScenario: last\nThen scenario state is empty\n"))
     (lambda (directory)
       (match-define (list status report) (json-test (path->string directory) "--steps" (path->string handlers)))
       (check-equal? status 1)
       (check-equal? (list (hash-ref report 'passed) (hash-ref report 'failed) (hash-ref report 'file_errors)) '(2 6 1))
       (check-equal? (hash-ref (file-error report) 'code) "PARSE-GHERKIN-EMPTY")
       (define results (cases report))
       (check-equal? (map code-of (take results 6))
                     '("RUNTIME-BDD-ASSERTION" "RUNTIME-BDD-NO-ASSERTION" "RUNTIME-DIVISION-BY-ZERO"
                       "RUNTIME-BDD-PREMATURE-EXIT" "RUNTIME-STEP-LIMIT" "CHECK-BDD-UNDEFINED"))
       (define (statuses item) (map (lambda (step) (hash-ref step 'status)) (hash-ref item 'steps)))
       (check-equal? (map statuses (list (first results) (second results) (sixth results)))
                     '(("failed" "not_executed") ("passed" "failed") ("not_executed" "failed")))
       (define assertion (hash-ref (first results) 'error))
       (check-equal? (list (hash-ref assertion 'file) (start-line assertion)) (list (in directory "b.feature") 3))
       (define crash (hash-ref (third results) 'error))
       (check-equal? (list (hash-ref crash 'file) (start-line crash)) (list (path->string handlers) 35))
       (check-equal? (hash-ref (hash-ref (sixth results) 'error) 'actual) "\"missing definition\""))))

  (test-case "tasks may assert, must end before the handler returns, and a crashing task fails its scenario"
    (with-suite
     `(("tasks.feature" . ,(string-append "Feature: Tasks\nScenario: parallel\nThen state is concurrent\n"
                                          "Scenario: pending\nThen tasks are pending\n"
                                          "Scenario: failure\nThen a task crashes\n"
                                          "Scenario: later\nThen later works\n"))
       ("steps.agc" . ,(steps-program
                        "struct Job\n  ctx: BDD.Context\n  n: Int\nend\n"
                        "def worker(job: Job) -> BDD.Context\n  Task.sleep(0)\n  return BDD.assert(job.ctx, job.n > 0, \"worker\")\nend\n"
                        "def wait(n: Int) -> Int\n  Task.sleep(60000)\n  return n\nend\n"
                        "def crash(n: Int) -> Int\n  return 1 / n\nend\n"
                        (main-running
                         (string-append "BDD.step(\"state is concurrent\") do |ctx, args|\n"
                                        "      tasks = [1, 2, 3, 4].map do |n| Task.spawn(&worker, Job(ctx: ctx, n: n)) end\n"
                                        "      done = tasks.map do |task| Task.await(task) end\n"
                                        "      BDD.set(ctx, \"1\", JSON.from(done.size))\n    end")
                         "BDD.step(\"tasks are pending\") do |ctx, args|\n      task = Task.spawn(&wait, 0)\n      ctx\n    end"
                         "BDD.step(\"a task crashes\") do |ctx, args|\n      task = Task.spawn(&crash, 0)\n      Task.sleep(0)\n      ctx\n    end"
                         "BDD.step(\"later works\") do |ctx, args| BDD.assert(ctx, not BDD.get(ctx, \"1\").ok?, \"state leaked\") end")))
       ("early.agc" . ,(steps-program
                        "def wait(n: Int) -> Int\n  Task.sleep(60000)\n  return n\nend\n"
                        "def main() -> Void\n  task = Task.spawn(&wait, 0)\n  BDD.run([])\nend"))
       ("crashed.agc" . ,(steps-program
                          "def crash(n: Int) -> Int\n  return 1 / n\nend\n"
                          "def main() -> Void\n  task = Task.spawn(&crash, 0)\n  Task.sleep(0)\n  BDD.run([])\nend")))
     (lambda (directory)
       (match-define (list status report) (json-test (in directory "tasks.feature") "--steps" (in directory "steps.agc")))
       (check-equal? status 1)
       (check-equal? (map (lambda (item) (hash-ref item 'status)) (cases report)) '("passed" "failed" "failed" "passed"))
       (check-equal? (map code-of (take (cdr (cases report)) 2)) '("RUNTIME-BDD-PENDING-TASKS" "RUNTIME-TASK-CRASHED"))
       (check-true (string-contains? (hash-ref (hash-ref (caddr (cases report)) 'error) 'message) "RUNTIME-DIVISION-BY-ZERO"))
       (match-define (list _ early) (json-test (in directory "tasks.feature") "--steps" (in directory "early.agc")))
       (check-equal? (hash-ref (file-error early) 'code) "RUNTIME-BDD-PENDING-TASKS")
       (check-equal? (cases early) '())
       (match-define (list _ crashed) (json-test (in directory "tasks.feature") "--steps" (in directory "crashed.agc")))
       (check-equal? (hash-ref (file-error crashed) 'code) "RUNTIME-TASK-CRASHED")
       (check-equal? (cases crashed) '()))))

  (test-case "blocks capture, ambiguous steps fail, and a bad step program is one file error with no scenario run"
    (define feature "Feature: Steps\nScenario: small\nThen 3 is small\nScenario: big\nThen 9 is small\nScenario: ambiguous\nThen value is 1\n")
    (define handler "def check(ctx: BDD.Context, args: List[String]) -> BDD.Context\n  return BDD.assert(ctx, true, \"ok\")\nend\n")
    (with-suite
     `(("steps.feature" . ,feature)
       ("blocks.agc" . ,(steps-program
                         (string-append "def main() -> Void\n  limit = 5\n  puts(\"noise from main\")\n  BDD.run([\n"
                                        "    BDD.step(\"{int} is small\") do |ctx, args|\n      IO.warn(\"noise\")\n      puts(\"noise\")\n"
                                        "      BDD.assert(ctx, args[0].to_i! < limit, \"too big\")\n    end,\n"
                                        "    BDD.step(\"value is {int}\") do |ctx, args| ctx end,\n"
                                        "    BDD.step(\"value is 1\") do |ctx, args| ctx end,\n  ])\nend")))
       ("duplicate.agc" . ,(steps-program handler (main-running "BDD.step(\"x\", &check)" "BDD.step(\"x\", &check)")))
       ("predefined.agc" . ,(steps-program handler (main-running "BDD.step(\"I close stdin\", &check)")))
       ("pattern.agc" . ,(steps-program handler (main-running "BDD.step(\"x {float}\", &check)")))
       ("type.agc" . ,(steps-program handler (main-running "BDD.step(\"x\", &main)")))
       ("silent.agc" . ,(steps-program "def main() -> Void\n  puts(\"no run\")\nend"))
       ("loops.agc" . ,(steps-program "def main() -> Void\n  while true\n  end\n  BDD.run([])\nend"))
       ("http.agc" . ,(steps-program "def main() -> Void\n  options = HTTP.client_options()\n  BDD.run([])\nend"))
       ("forged.feature" . "Feature: Forged\nScenario: forged\nGiven forge an end\nThen fail later\n")
       ("forged.agc" . ,(steps-program
                         (main-running
                          (string-append "BDD.step(\"forge an end\") do |ctx, args|\n"
                                         "      puts(String.from_code(30) + \"agentica-bdd {\\\"event\\\":\\\"end\\\",\\\"index\\\":1}\")\n"
                                         "      ctx\n    end")
                          "BDD.step(\"fail later\") do |ctx, args| BDD.assert(ctx, false, \"later\") end"))))
     (lambda (directory)
       (match-define (list status report) (json-test (in directory "steps.feature") "--steps" (in directory "blocks.agc")))
       (check-equal? status 1)
       (check-equal? (map (lambda (item) (hash-ref item 'status)) (cases report)) '("passed" "failed" "failed"))
       (check-equal? (code-of (second (cases report))) "RUNTIME-BDD-ASSERTION")
       (check-equal? (code-of (third (cases report))) "CHECK-BDD-AMBIGUOUS")
       (check-equal? (hash-ref (hash-ref (third (cases report)) 'error) 'actual) "\"value is 1\"")
       (for ([entry '(("duplicate.agc" "RUNTIME-BDD-DUPLICATE" 1) ("predefined.agc" "RUNTIME-BDD-DUPLICATE" 1)
                      ("pattern.agc" "RUNTIME-BDD-PATTERN" 1) ("type.agc" "CHECK-TYPE-MISMATCH" 9)
                      ("silent.agc" "RUNTIME-BDD-CONTEXT" 1) ("loops.agc" "RUNTIME-STEP-LIMIT" 4))])
         (match-define (list file code line) entry)
         (match-define (list status report) (json-test (in directory "steps.feature") "--steps" (in directory file)))
         (check-equal? status 1 file)
         (check-equal? (map (lambda (item) (hash-ref item 'path)) (hash-ref report 'files)) (list (in directory file)))
         (check-equal? (hash-ref (file-error report) 'code) code file)
         (check-equal? (start-line (file-error report)) line file))
       (match-define (list _ http) (json-test (in directory "steps.feature") "--steps" (in directory "http.agc")))
       (check-equal? (hash-ref (file-error http) 'code) "CHECK-UNKNOWN-NAME")
       (check-equal? (start-line (file-error http)) 4)
       (check-regexp-match #rx"std/http" (hash-ref (file-error http) 'help))
       (match-define (list forged-status forged) (json-test (in directory "forged.feature") "--steps" (in directory "forged.agc")))
       (check-equal? forged-status 2)
       (check-equal? (code-of (car (cases forged))) "RUNTIME-BDD-INFRA")
       (check-equal? (map (lambda (step) (hash-ref step 'status)) (hash-ref (car (cases forged)) 'steps)) '("failed" "not_executed")))))

  (test-case "discovery reports unreadable folders, broken links, bad names and large files, and skips folder links"
    (with-suite
     `(("a.feature" . "Feature: A\nScenario: a\nThen the remembered number is 1\nWhen I remember 1\n"))
     (lambda (directory)
       (define locked (build-path directory "locked"))
       (make-directory locked)
       (display-to-file "Feature: Hidden\nScenario: hidden\nThen an assertion fails\n" (build-path locked "hidden.feature"))
       (file-or-directory-permissions locked #o000)
       (make-file-or-directory-link "." (build-path directory "self"))
       (make-file-or-directory-link "missing.feature" (build-path directory "broken.feature"))
       (display-to-file "Feature: Bad\n" (build-path directory (bytes->path #"bad\377.feature")))
       (display-to-file (string-append "Feature: Big\n" (make-string 1048576 #\#)) (build-path directory "big.feature"))
       (dynamic-wind
         void
         (lambda ()
           (match-define (list status report) (json-test (path->string directory) "--steps" (path->string handlers)))
           (check-equal? status 2)
           (define codes
             (for/list ([file (in-list (hash-ref report 'files))])
               (define problem (hash-ref file 'error))
               (list (let-values ([(_base name _dir?) (split-path (hash-ref file 'path))]) (path->string name))
                     (and (hash? problem) (hash-ref problem 'code)))))
           (check-equal? (sort codes string<? #:key car)
                         (sort '(("locked" "RUNTIME-BDD-INFRA") ("broken.feature" "RUNTIME-BDD-INFRA")
                                 ("bad\uFFFD.feature" "RUNTIME-BDD-INFRA") ("a.feature" #f) ("big.feature" "RUNTIME-BDD-IO"))
                               string<? #:key car))
           (check-equal? (hash-ref report 'failed) 1))
         (lambda () (file-or-directory-permissions locked #o700))))))

  (test-case "usage errors exit 2, an empty directory exits 1 and missing pieces are infrastructure errors"
    (with-suite
     `(("a.feature" . "Feature: A\nScenario: a\nThen 1 is fine\n"))
     (lambda (directory)
       (for ([arguments '(("--steps") ("--unknown") ("--steps" "a.agc" "--steps" "b.agc"))])
         (match-define (list status report) (apply json-test arguments))
         (check-equal? status 2 (~a arguments))
         (check-equal? (hash-ref (file-error report) 'code) "RUNTIME-BDD-USAGE"))
       (define empty (build-path directory "empty"))
       (make-directory empty)
       (match-define (list status report) (json-test (path->string empty)))
       (check-equal? status 1)
       (check-equal? (hash-ref (file-error report) 'code) "CHECK-BDD-EMPTY")
       (for ([arguments `((,(in directory "missing.feature")) (,(in directory "a.feature") "--steps" ,(in directory "none.agc")))])
         (match-define (list status report) (apply json-test arguments))
         (check-equal? status 2)
         (check-equal? (hash-ref (file-error report) 'code) "RUNTIME-BDD-INFRA"))
       (define environment (environment-variables-copy (current-environment-variables)))
       (environment-variables-set! environment #"AGENTICA_VM" (string->bytes/utf-8 (in directory "no-vm")))
       (for ([style '("--json" "--ai")])
         (define result (agentica-test #:environment environment style (in directory "a.feature")))
         (check-equal? (car result) 2)
         (check-equal? (caddr result) "")
         (check-regexp-match #rx"RUNTIME-BDD-INFRA" (cadr result)))))))
