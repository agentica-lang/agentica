#lang racket

(require (except-in rackunit check) racket/runtime-path json
         "../src/modules.rkt" "../src/checker.rkt" "../src/evaluator.rkt"
         "../src/diagnostic.rkt" "../src/source.rkt" "../src/bdd-runner.rkt")

(define-runtime-path main-file "../src/main.rkt")
(define-runtime-path example "../examples/json-modules.agc")

(define (with-files files run)
  (define directory (make-temporary-file "agentica-modules~a" 'directory))
  (dynamic-wind void
    (lambda ()
      (for ([entry (in-list files)])
        (define path (build-path directory (car entry)))
        (make-parent-directory* path)
        (display-to-file (cdr entry) path))
      (run directory))
    (lambda () (delete-directory/files directory))))

(define (checked path)
  (define linked (load-program path))
  (if (diagnostic? linked) linked (check linked)))

(define (run path #:max-steps [steps #f])
  (define program (checked path))
  (when (diagnostic? program) (error 'modules-test "~a" (format-diagnostic program)))
  (define out (open-output-string))
  (define result (evaluate program #:out out #:max-steps steps))
  (values (get-output-string out) result))

(module+ test
  (test-case "imports share canonical identities and resolve relative to each file"
    (with-files
     '(("library/models.agc" . "export struct Value\n  n: Int\nend\nexport def read(value: Value) -> Int\n  return value.n\nend\ndef main() -> Void\n  puts(\"must not run\")\nend\n")
       ("library/outer.agc" . "import \"models.agc\" as Models\nexport def make(n: Int) -> Models.Value\n  return Models.Value(n: n)\nend\n")
       ("root.agc" . "import \"library/models.agc\" as First\nimport \"library/../library/models.agc\" as Second\nimport \"library/outer.agc\" as Outer\ndef main() -> Void\n  value: Second.Value = Outer.make(42)\n  IO.inspect(First.read(value))\n  IO.inspect(Second.read(First.Value(n: 7)))\nend\n"))
     (lambda (directory)
       (define-values (out result) (run (build-path directory "root.agc")))
       (check-equal? out "42\n7\n")
       (check-equal? result (void)))))

  (test-case "private helpers and same names in different modules stay separate"
    (with-files
     '(("a.agc" . "def helper(n: Int) -> Int\n  return n + 1\nend\nexport def apply(n: Int) -> Int\n  return helper(n)\nend\n")
       ("b.agc" . "def helper(n: Int) -> Int\n  return n + 10\nend\nexport def apply(n: Int) -> Int\n  return helper(n)\nend\n")
       ("root.agc" . "import \"a.agc\" as A\nimport \"b.agc\" as B\ndef main() -> Void\n  IO.inspect(List.map([1, 2], &A.apply))\n  IO.inspect(List.map([1, 2], &B.apply))\nend\n"))
     (lambda (directory)
       (define-values (out result) (run (build-path directory "root.agc")))
       (check-equal? out "[2, 3]\n[11, 12]\n")
       (check-equal? result (void)))))

  (test-case "module errors are located and do not expose private declarations"
    (for ([entry
           '(("import \"missing.agc\" as Missing\n" "" CHECK-IMPORT-IO)
             ("import \"module.agc\" as M\n" "  M.hidden()\n" CHECK-IMPORT-NAME)
             ("import \"module.agc\" as M\n" "  x = M.Secret(value: 1)\n" CHECK-IMPORT-NAME)
             ("import \"module.agc\" as M\nimport \"module.agc\" as M\n" "" CHECK-REDEFINED-NAME)
             ("import \"module.agc\" as JSON\n" "" CHECK-REDEFINED-NAME)
             ("import \"module.txt\" as M\n" "" CHECK-IMPORT-PATH)
             ("" "  x = String.nope(\"a\")\n" CHECK-UNKNOWN-NAME)
             ("" "  x = Mpa.put(1)\n" CHECK-UNKNOWN-NAME)
             ("" "  x = IO.nope()\n" CHECK-UNKNOWN-NAME)
             ("" "  x: Missing.Value = 1\n" CHECK-IMPORT-NAME))])
      (with-files
       (list (cons "module.agc" "struct Secret\n  value: Int\nend\ndef hidden() -> Void\nend\nexport struct Public\nend\n")
             (cons "root.agc" (string-append (car entry) "def main() -> Void\n" (cadr entry) "end\n")))
       (lambda (directory)
         (define problem (checked (build-path directory "root.agc")))
         (check-true (diagnostic? problem))
         (check-equal? (diagnostic-code problem) (caddr entry))
         (check-equal? (source-name (source-span-source (diagnostic-span problem)))
                       (path->string (build-path directory "root.agc")))))))

  (test-case "cycles and dependency runtime failures retain original file spans"
    (with-files
     '(("root.agc" . "import \"a.agc\" as A\ndef main() -> Void\nend\n")
       ("a.agc" . "import \"root.agc\" as Root\n"))
     (lambda (directory)
       (define problem (checked (build-path directory "root.agc")))
       (check-equal? (diagnostic-code problem) 'CHECK-IMPORT-CYCLE)
       (check-equal? (source-name (source-span-source (diagnostic-span problem)))
                     (path->string (build-path directory "a.agc")))))
    (with-files
     '(("root.agc" . "import \"a.agc\" as A\ndef main() -> Void\n  IO.inspect(A.fail(0))\nend\n")
       ("a.agc" . "export def fail(n: Int) -> Int\n  return 1 / n\nend\n"))
     (lambda (directory)
       (define-values (out problem) (run (build-path directory "root.agc")))
       (check-equal? (diagnostic-code problem) 'RUNTIME-DIVISION-BY-ZERO)
       (check-equal? (source-position-line (source-span-start (diagnostic-span problem))) 2)
       (check-equal? (source-name (source-span-source (diagnostic-span problem)))
                     (path->string (build-path directory "a.agc"))))))

  (test-case "imported task callbacks keep the execution budget"
    (with-files
     '(("root.agc" . "import \"worker.agc\" as Worker\ndef main() -> Void\n  task = Task.spawn(&Worker.run, 0)\n  IO.inspect(Task.await(task))\nend\n")
       ("worker.agc" . "export def run(n: Int) -> Int\n  while n < 100\n    n = n + 1\n  end\n  return n\nend\n"))
     (lambda (directory)
       (define-values (out result) (run (build-path directory "root.agc")))
       (check-equal? out "100\n")
       (check-equal? result (void))
       (define-values (limited-out problem) (run (build-path directory "root.agc") #:max-steps 30))
       (check-equal? (diagnostic-code problem) 'RUNTIME-STEP-LIMIT))))

  (test-case "BDD can register imported handlers"
    (with-files
     '(("steps.agc" . "import \"assertions.agc\" as Assertions\ndef main() -> Void\n  BDD.step(\"it works\", &Assertions.verify)\nend\n")
       ("assertions.agc" . "export def verify(args: List[String]) -> Void\n  BDD.assert(true, \"imported handler\")\nend\n")
       ("test.feature" . "Feature: Modules\nScenario: Imported handler\nThen it works\n"))
     (lambda (directory)
       (define report (run-bdd (list (build-path directory "test.feature"))
                               #:steps (list (build-path directory "steps.agc"))))
       (check-true (hash-ref report 'ok)))))

  (test-case "combined JSON module example runs through the CLI"
    (define executable (getenv "AGENTICA_TEST_EXECUTABLE"))
    (define-values (process output input errors)
      (if executable
          (subprocess #f #f #f executable example)
          (subprocess #f #f #f (find-system-path 'exec-file) main-file example)))
    (close-output-port input)
    (define lines (port->lines output))
    (define error-text (port->string errors))
    (subprocess-wait process)
    (close-input-port output)
    (close-input-port errors)
    (check-equal? (subprocess-status process) 0)
    (check-equal? error-text "")
    (check-equal? (string->jsexpr (car lines)) (hasheq 'result 42))
    (check-equal? (cadr lines) "[2, 4]")
    (define schema (string->jsexpr (caddr lines)))
    (check-equal? (hash-ref schema 'required) '("left" "right"))))
