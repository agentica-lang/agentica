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
  (test-case "embedded String queue preserves FIFO and old values without local std files"
    (with-files
     '(("std/queue.agc" . "this local file must not be loaded\n")
       ("root.agc" . "import \"std/queue.agc\" as Queue\nimport \"std/queue.agc\" as Again\ndef main() -> Void\n  original = Queue.new()\n  q: Again.QueueState = Queue.push(original, \"\")\n  q = Queue.push(q, \"same\")\n  q = Queue.push(q, \"same\")\n  IO.inspect(Queue.size(q))\n  IO.inspect(Queue.empty?(original))\n  IO.inspect(not Result.ok?(Queue.pop(original)))\n  IO.inspect(not Result.ok?(Queue.peek(original)))\n  IO.inspect(Result.unwrap!(Queue.peek(q)))\n  while not Queue.empty?(q)\n    item = Result.unwrap!(Queue.pop(q))\n    puts(item.value)\n    q = item.remaining\n  end\n  IO.inspect(Queue.size(q))\nend\n"))
     (lambda (directory)
       (define path (build-path directory "root.agc"))
       (define-values (out result) (run path))
       (check-equal? out "3\ntrue\ntrue\ntrue\n\"\"\n\nsame\nsame\n0\n")
       (check-equal? result (void))
       ;; Exercise the same import with the release executable in compiled CI.
       (define executable (getenv "AGENTICA_TEST_EXECUTABLE"))
       (define-values (process output input errors)
         (parameterize ([current-directory (find-system-path 'temp-dir)])
           (if executable
               (subprocess #f #f #f executable path)
               (subprocess #f #f #f (find-system-path 'exec-file) main-file path))))
       (close-output-port input)
       (define cli-out (port->string output))
       (define cli-err (port->string errors))
       (subprocess-wait process)
       (close-input-port output)
       (close-input-port errors)
       (check-equal? (subprocess-status process) 0 cli-err)
       (check-equal? cli-err "")
       (check-equal? cli-out out))))

  (test-case "pkg roots search project, environment, then user data independent of cwd"
    (with-files
     '(("root.agc" . "import \"pkg/value.agc\" as Value\ndef main() -> Void\n  puts(Value.read())\nend\n")
       ("agc_libs/value.agc" . "export def read() -> String\n  return \"project\"\nend\n")
       ("first/value.agc" . "import \"helper.agc\" as Helper\nexport def read() -> String\n  return Helper.read()\nend\n")
       ("first/helper.agc" . "export def read() -> String\n  return \"first\"\nend\n")
       ("second/value.agc" . "export def read() -> String\n  return \"second\"\nend\n")
       ("data/agentica/lib/value.agc" . "export def read() -> String\n  return \"user\"\nend\n"))
     (lambda (directory)
       (define env (environment-variables-copy (current-environment-variables)))
       (define windows? (eq? (system-type 'os) 'windows))
       (environment-variables-set! env #"AGENTICA_PATH"
         (string->bytes/utf-8
          (string-join (map (lambda (name) (path->string (build-path directory name)))
                            '("absent" "first" "second")) (if windows? ";" ":"))))
       (environment-variables-set! env (if windows? #"LOCALAPPDATA" #"XDG_DATA_HOME")
                                   (path->bytes (build-path directory "data")))
       (parameterize ([current-environment-variables env]
                      [current-directory (find-system-path 'temp-dir)])
         (for ([expected '("project\n" "first\n" "second\n" "user\n")]
               [remove '("agc_libs" "first" "second" #f)])
           (define-values (out result) (run (build-path directory "root.agc")))
           (check-equal? out expected)
           (check-equal? result (void))
           (when remove (delete-directory/files (build-path directory remove))))))))

  (test-case "reserved library namespaces reject traversal and retain import spans"
    (for ([entry '(("std/../queue.agc" CHECK-IMPORT-PATH)
                   ("std//queue.agc" CHECK-IMPORT-PATH)
                   ("std/missing.agc" CHECK-IMPORT-IO)
                   ("pkg/../outside.agc" CHECK-IMPORT-PATH)
                   ("pkg/agentica-test-nonexistent-stdlib-library.agc" CHECK-IMPORT-IO))])
      (with-files
       (list (cons "root.agc" (format "import ~s as Q\ndef main() -> Void\nend\n" (car entry))))
       (lambda (directory)
         (define env (environment-variables-copy (current-environment-variables)))
         (environment-variables-set! env #"AGENTICA_PATH" #"")
         (define problem (parameterize ([current-environment-variables env])
                           (checked (build-path directory "root.agc"))))
         (check-true (diagnostic? problem))
         (check-equal? (diagnostic-code problem) (cadr entry))
         (check-equal? (source-position-line (source-span-start (diagnostic-span problem))) 1)))))

  (test-case "pkg imports reject relative environment roots and escaping symlinks"
    (with-files
     '(("root.agc" . "import \"pkg/value.agc\" as Value\ndef main() -> Void\nend\n")
       ("outside.agc" . "export def read() -> Int\n  return 1\nend\n"))
     (lambda (directory)
       (define env (environment-variables-copy (current-environment-variables)))
       (environment-variables-set! env #"AGENTICA_PATH" #"relative")
       (parameterize ([current-environment-variables env])
         (check-equal? (diagnostic-code (checked (build-path directory "root.agc")))
                       'CHECK-IMPORT-PATH))
       ;; Unix symlinks need no privilege; Windows link creation may require it.
       (unless (eq? (system-type 'os) 'windows)
         (make-directory (build-path directory "agc_libs"))
         (make-file-or-directory-link (build-path directory "outside.agc")
                                      (build-path directory "agc_libs" "value.agc"))
         (environment-variables-set! env #"AGENTICA_PATH" #"")
         (parameterize ([current-environment-variables env])
           (check-equal? (diagnostic-code (checked (build-path directory "root.agc")))
                         'CHECK-IMPORT-PATH))))))

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
       ("assertions.agc" . "import \"std/queue.agc\" as Queue\nexport def verify(args: List[String]) -> Void\n  q = Queue.push(Queue.new(), \"imported handler\")\n  BDD.assert(Result.unwrap!(Queue.peek(q)) == \"imported handler\", \"imported handler\")\nend\n")
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
    (check-equal? (hash-ref schema 'required) '("left" "right")))

  (test-case "imported generic enums resolve constructors and exhaustive patterns"
    (with-files
     '(("option.agc" . "export enum Option[T]\n  Some(T)\n  None\nend\n")
       ("root.agc" . "import \"option.agc\" as Domain\ndef main() -> Void\n  value: Domain.Option[Int] = Domain.Option.Some(7)\n  case value do\n    Domain.Option.Some(item) ->\n      puts(String.from_int(item))\n    Domain.Option.None ->\n      puts(\"empty\")\n  end\n  empty: Domain.Option[String] = Domain.Option.None()\n  case empty do\n    Domain.Option.Some(item) ->\n      puts(item)\n    Domain.Option.None ->\n      puts(\"none\")\n  end\nend\n"))
     (lambda (directory)
       (define-values (out result) (run (build-path directory "root.agc")))
       (check-equal? out "7\nnone\n")
       (check-equal? result (void)))))

  (test-case "private imported enums remain inaccessible"
    (with-files
     '(("option.agc" . "enum Option[T]\n  Some(T)\nend\n")
       ("root.agc" . "import \"option.agc\" as Domain\ndef main() -> Void\n  value: Domain.Option[Int] = Domain.Option.Some(1)\nend\n"))
     (lambda (directory)
       (define problem (checked (build-path directory "root.agc")))
       (check-equal? (diagnostic-code problem) 'CHECK-IMPORT-NAME)))))
