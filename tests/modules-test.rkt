#lang racket

(require (except-in rackunit check) racket/runtime-path json
         "../src/modules.rkt" "../src/checker.rkt" "../src/evaluator.rkt"
         "../src/diagnostic.rkt" "../src/source.rkt" "../src/bdd-runner.rkt")

(define-runtime-path main-file "../src/main.rkt")
(define-runtime-path example "../examples/json-modules.agc")

(for ([name '(#"AGENTICA_VM_TRACE" #"AGENTICA_VM_TRACE_FILE")])
  (environment-variables-set! (current-environment-variables) name #f))

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
  (test-case "methods work on values whose types come from another file"
    (with-files
     '(("lib.agc" . "export struct Box\n  label: String\nend\n\nexport def make(text: String) -> Box\n  return Box(label: text)\nend\n\n")
       ("root.agc" . "import \"lib\" as Lib\ndef main() -> Void\n  b = Lib.make(\" hi \")\n  IO.inspect(b.label.strip.upcase.size)\nend\n\n"))
     (lambda (directory)
       (define-values (out result) (run (build-path directory "root.agc")))
       (check-equal? out "2\n"))))

  (test-case "blocks in an imported file call that file's private helpers and types"
    (with-files
     '(("lib.agc" . "struct Pair\n  n: Int\nend\n\ndef twice(n: Int) -> Int\n  return n * 2\nend\n\nexport def doubled(xs: List[Int]) -> List[Int]\n  pairs = xs.map do |x| Pair(n: twice(x)) end\n  return pairs.map do |p: Pair| p.n end\nend\n\n")
       ("root.agc" . "import \"lib\" as Lib\ndef main() -> Void\n  IO.inspect(Lib.doubled([1, 2]))\nend\n\n"))
     (lambda (directory)
       (define-values (out result) (run (build-path directory "root.agc")))
       (check-equal? out "[2, 4]\n"))))

  (test-case "interpolation in an imported function reaches that file's private helpers"
    (with-files
     '(("lib.agc" . "def twice(n: Int) -> Int\n  return n * 2\nend\n\nexport def label(n: Int) -> String\n  return \"n=#{twice(n)}\"\nend\n\n")
       ("root.agc" . "import \"lib\" as Lib\ndef main() -> Void\n  puts(Lib.label(3))\nend\n\n"))
     (lambda (directory)
       (define-values (out result) (run (build-path directory "root.agc")))
       (check-equal? out "n=6\n"))))

  (test-case "embedded String queue preserves FIFO and old values without local std files"
    (with-files
     '(("std/queue.agc" . "this local file must not be loaded\n")
       ("root.agc" . "import \"std/queue\" as Queue\nimport \"std/queue\" as Again\ndef main() -> Void\n  original = Queue.new()\n  q: Again.QueueState = Queue.push(original, \"\")\n  q = Queue.push(q, \"same\")\n  q = Queue.push(q, \"same\")\n  IO.inspect(Queue.size(q))\n  IO.inspect(Queue.empty?(original))\n  IO.inspect(not Result.ok?(Queue.pop(original)))\n  IO.inspect(not Result.ok?(Queue.peek(original)))\n  IO.inspect(Result.unwrap!(Queue.peek(q)))\n  while not Queue.empty?(q)\n    item = Result.unwrap!(Queue.pop(q))\n    puts(item.value)\n    q = item.remaining\n  end\n  IO.inspect(Queue.size(q))\nend\n\n"))
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
     '(("root.agc" . "import \"pkg/value\" as Value\ndef main() -> Void\n  puts(Value.read())\nend\n\n")
       ("agc_libs/value.agc" . "export def read() -> String\n  return \"project\"\nend\n\n")
       ("first/value.agc" . "import \"helper\" as Helper\nexport def read() -> String\n  return Helper.read()\nend\n\n")
       ("first/helper.agc" . "export def read() -> String\n  return \"first\"\nend\n\n")
       ("second/value.agc" . "export def read() -> String\n  return \"second\"\nend\n\n")
       ("data/agentica/lib/value.agc" . "export def read() -> String\n  return \"user\"\nend\n\n"))
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
    (for ([entry '(("std/../queue" CHECK-IMPORT-PATH)
                   ("std//queue" CHECK-IMPORT-PATH)
                   ("std/missing" CHECK-IMPORT-IO)
                   ("pkg/../outside" CHECK-IMPORT-PATH)
                   ("pkg/agentica-test-nonexistent-stdlib-library" CHECK-IMPORT-IO))])
      (with-files
       (list (cons "root.agc" (format "import ~s as Q\ndef main() -> Void\nend\n\n" (car entry))))
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
     '(("root.agc" . "import \"pkg/value\" as Value\ndef main() -> Void\nend\n\n")
       ("outside.agc" . "export def read() -> Int\n  return 1\nend\n\n"))
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
     '(("library/models.agc" . "export struct Value\n  n: Int\nend\n\nexport def read(value: Value) -> Int\n  return value.n\nend\n\ndef main() -> Void\n  puts(\"must not run\")\nend\n\n")
       ("library/outer.agc" . "import \"models\" as Models\nexport def make(n: Int) -> Models.Value\n  return Models.Value(n: n)\nend\n\n")
       ("root.agc" . "import \"library/models\" as First\nimport \"library/../library/models\" as Second\nimport \"library/outer\" as Outer\ndef main() -> Void\n  value: Second.Value = Outer.make(42)\n  IO.inspect(First.read(value))\n  IO.inspect(Second.read(First.Value(n: 7)))\nend\n\n"))
     (lambda (directory)
       (define-values (out result) (run (build-path directory "root.agc")))
       (check-equal? out "42\n7\n")
       (check-equal? result (void)))))

  (test-case "private helpers and same names in different modules stay separate"
    (with-files
     '(("a.agc" . "def helper(n: Int) -> Int\n  return n + 1\nend\n\nexport def apply(n: Int) -> Int\n  return helper(n)\nend\n\n")
       ("b.agc" . "def helper(n: Int) -> Int\n  return n + 10\nend\n\nexport def apply(n: Int) -> Int\n  return helper(n)\nend\n\n")
       ("root.agc" . "import \"a\" as A\nimport \"b\" as B\ndef main() -> Void\n  IO.inspect(List.map([1, 2], &A.apply))\n  IO.inspect(List.map([1, 2], &B.apply))\nend\n\n"))
     (lambda (directory)
       (define-values (out result) (run (build-path directory "root.agc")))
       (check-equal? out "[2, 3]\n[11, 12]\n")
       (check-equal? result (void)))))

  (test-case "imported structs and enums print their declared names"
    (with-files
     '(("a.agc" . "export struct Point\n  x: Int\nend\n\nexport enum Shape\n  Dot(Point)\n  Empty\nend\n\nexport def show() -> Void\n  puts(\"#{Point(x: 2)} #{Shape.Empty}\")\nend\n\n")
       ("b.agc" . "export struct Point\n  y: Int\nend\n\n")
       ("root.agc" . "import \"a\" as A\nimport \"b\" as B\n\nstruct Both\n  a: A.Point\n  b: B.Point\nend\n\ndef main() -> Void\n  A.show()\n  p = A.Point(x: 3)\n  puts(p)\n  puts(B.Point(y: 4).inspect)\n  puts([A.Shape.Dot(p)].to_s)\n  puts({\"k\": ok(A.Shape.Empty)})\n  IO.warn(p)\n  IO.warn(JSON.schema(Both))\nend\n\n"))
     (lambda (directory)
       (define program (checked (build-path directory "root.agc")))
       (define out (open-output-string))
       (define err (open-output-string))
       (check-equal? (evaluate program #:out out #:err err) (void))
       (check-equal? (get-output-string out)
                     (string-append "Point(x: 2) Shape.Empty\nPoint(x: 3)\nPoint(y: 4)\n"
                                    "[Shape.Dot(Point(x: 3))]\n{\"k\": ok(Shape.Empty)}\n"))
       (define warnings (string-split (get-output-string err) "\n"))
       (check-equal? (car warnings) "Point(x: 3)")
       (check-equal? (hash-count (hash-ref (string->jsexpr (cadr warnings)) '$defs)) 2)))
    (with-files
     '(("a.agc" . "export struct Point\n  x: Int\nend\n\n")
       ("root.agc" . "import \"a\" as A\ndef main() -> Void\n  n: Int = A.Point(x: 1)\nend\n\n"))
     (lambda (directory)
       (define problem (checked (build-path directory "root.agc")))
       (check-equal? (diagnostic-code problem) 'CHECK-TYPE-MISMATCH)
       (check-equal? (diagnostic-actual problem) "Point")))
    (with-files
     '(("a.agc" . "export struct Point\n  x: Int\nend\n\nexport def make(x: Int) -> Point\n  return Point(x: x)\nend\n\n")
       ("root.agc" . "import \"a\" as A\ndef main() -> Void\n  n = A.Point(x: 1).z\nend\n\n")
       ("arity.agc" . "import \"a\" as A\ndef main() -> Void\n  p = A.make()\nend\n\n"))
     (lambda (directory)
       (define problem (checked (build-path directory "root.agc")))
       (check-equal? (diagnostic-code problem) 'CHECK-UNKNOWN-FIELD)
       (define start (source-span-start (diagnostic-span problem)))
       (check-equal? (list (source-position-line start) (source-position-column start)) '(3 7))
       (define arity (checked (build-path directory "arity.agc")))
       (check-equal? (diagnostic-code arity) 'CHECK-ARITY)
       (check-false (regexp-match? #rx"@" (diagnostic-callee arity)))))
    (with-files
     '(("bad.agc" . "struct Point\n  x: Int\nend\n\nstruct Pair\n  p: Pont\nend\n\n")
       ("calls.agc" . "def helper() -> Int\n  return 1\nend\n\nexport def go() -> Int\n  return helpr()\nend\n\n")
       ("types.agc" . "import \"bad\" as B\ndef main() -> Void\nend\n\n")
       ("funcs.agc" . "import \"calls\" as C\n\ndef helpe() -> Int\n  return 2\nend\n\ndef main() -> Void\n  n = C.go()\nend\n\n"))
     (lambda (directory)
       (define type-problem (checked (build-path directory "types.agc")))
       (check-equal? (diagnostic-code type-problem) 'CHECK-UNKNOWN-TYPE)
       (define span (diagnostic-span type-problem))
       (check-equal? (source-name (source-span-source span)) (path->string (build-path directory "bad.agc")))
       (check-equal? (list (source-position-line (source-span-start span))
                           (source-position-column (source-span-start span)))
                     '(6 6))
       (check-true (string? (diagnostic-help type-problem)))
       (check-false (regexp-match? #rx"@" (diagnostic-help type-problem)))
       (define call-problem (checked (build-path directory "funcs.agc")))
       (check-equal? (diagnostic-code call-problem) 'CHECK-UNKNOWN-NAME)
       (check-true (string? (diagnostic-help call-problem)))
       (check-regexp-match #rx"helper" (diagnostic-help call-problem))
       (check-false (regexp-match? #rx"@" (diagnostic-help call-problem))))))

  (test-case "module errors are located and do not expose private declarations"
    (for ([entry
           '(("import \"missing\" as Missing\n" "" CHECK-IMPORT-IO)
             ("import \"module\" as M\n" "  M.hidden()\n" CHECK-IMPORT-NAME)
             ("import \"module\" as M\n" "  x = M.Secret(value: 1)\n" CHECK-IMPORT-NAME)
             ("import \"module\" as M\nimport \"module\" as M\n" "" CHECK-REDEFINED-NAME)
             ("import \"module\" as JSON\n" "" CHECK-REDEFINED-NAME)
             ("import \"module.txt\" as M\n" "" CHECK-IMPORT-PATH)
             ("" "  x = String.nope(\"a\")\n" CHECK-UNKNOWN-NAME)
             ("" "  x = Mpa.put(1)\n" CHECK-UNKNOWN-NAME)
             ("" "  x = IO.nope()\n" CHECK-UNKNOWN-NAME)
             ("" "  x: Missing.Value = 1\n" CHECK-IMPORT-NAME))])
      (with-files
       (list (cons "module.agc" "struct Secret\n  value: Int\nend\n\ndef hidden() -> Void\nend\n\nexport struct Public\nend\n\n")
             (cons "root.agc" (string-append (car entry) "def main() -> Void\n" (cadr entry) "end\n\n")))
       (lambda (directory)
         (define problem (checked (build-path directory "root.agc")))
         (check-true (diagnostic? problem))
         (check-equal? (diagnostic-code problem) (caddr entry))
         (check-equal? (source-name (source-span-source (diagnostic-span problem)))
                       (path->string (build-path directory "root.agc")))))))

  (test-case "import paths name modules without an extension"
    (with-files
     '(("lib/util.agc" . "export def read() -> String\n  return \"util\"\nend\n\n")
       ("app/root.agc" . "import \"../lib/util\" as Util\ndef main() -> Void\n  puts(Util.read())\nend\n\n"))
     (lambda (directory)
       (define-values (out result) (run (build-path directory "app" "root.agc")))
       (check-equal? out "util\n")))
    (for ([entry '(("lib/util.agc" "import \"lib/util\" as Util")
                   ("std/queue.agc" "import \"std/queue\" as Util")
                   ("lib/util.rb" #f)
                   ("lib/" #f)
                   ("" #f))])
      (with-files
       (list (cons "lib/util.agc" "export def read() -> String\n  return \"util\"\nend\n\n")
             (cons "root.agc" (format "def helper() -> Void\nend\n\nimport ~s as Util\ndef main() -> Void\nend\n\n" (car entry))))
       (lambda (directory)
         (define problem (checked (build-path directory "root.agc")))
         (check-equal? (diagnostic-code problem) 'CHECK-IMPORT-PATH)
         (define start (source-span-start (diagnostic-span problem)))
         (check-equal? (list (source-position-line start) (source-position-column start)) '(4 1))
         (when (cadr entry)
           (check-regexp-match (regexp (regexp-quote (cadr entry))) (diagnostic-help problem)))))))

  (test-case "nullary variants need no parentheses, locally and through an alias"
    (with-files
     '(("shapes.agc" . "export enum Shape\n  Dot\n  Box(Int)\nend\n\n")
       ("root.agc" . "import \"shapes\" as S\n\nenum Command\n  Show\n  Add(Int)\nend\n\ndef main() -> Void\n  c = Command.Show\n  case c\n    Command.Show -> puts(\"show\")\n    Command.Add(n) -> puts(n.to_s)\n  end\n  s = S.Shape.Dot\n  case s\n    S.Shape.Dot -> puts(\"dot\")\n    _ -> puts(\"other\")\n  end\nend\n\n"))
     (lambda (directory)
       (define-values (out result) (run (build-path directory "root.agc")))
       (check-equal? out "show\ndot\n")))
    (with-files
     '(("root.agc" . "def main() -> Void\n  c = Color.Red\nend\n\n"))
     (lambda (directory)
       (define problem (checked (build-path directory "root.agc")))
       (check-equal? (diagnostic-code problem) 'CHECK-IMPORT-NAME)
       (check-equal? (source-position-line (source-span-start (diagnostic-span problem))) 2)
       (check-regexp-match #rx"enum Color" (diagnostic-help problem))))
    (with-files
     '(("root.agc" . "def main() -> Void\n  p: Geo.Point = nil\nend\n\n"))
     (lambda (directory)
       (define problem (checked (build-path directory "root.agc")))
       (check-equal? (diagnostic-code problem) 'CHECK-IMPORT-NAME)
       (check-false (regexp-match? #rx"enum" (diagnostic-help problem)))))
    (with-files
     '(("root.agc" . "def main() -> Void\n  r = Result.Ok\nend\n\n"))
     (lambda (directory)
       (define problem (checked (build-path directory "root.agc")))
       (check-equal? (diagnostic-code problem) 'CHECK-IMPORT-NAME)
       (check-regexp-match #rx"ok\\(value\\)" (diagnostic-help problem)))))

  (test-case "cycles and dependency runtime failures retain original file spans"
    (with-files
     '(("root.agc" . "import \"a\" as A\ndef main() -> Void\nend\n\n")
       ("a.agc" . "import \"root\" as Root\n"))
     (lambda (directory)
       (define problem (checked (build-path directory "root.agc")))
       (check-equal? (diagnostic-code problem) 'CHECK-IMPORT-CYCLE)
       (check-equal? (source-name (source-span-source (diagnostic-span problem)))
                     (path->string (build-path directory "a.agc")))))
    (with-files
     '(("root.agc" . "import \"a\" as A\ndef main() -> Void\n  IO.inspect(A.fail(0))\nend\n\n")
       ("a.agc" . "export def fail(n: Int) -> Int\n  return 1 / n\nend\n\n"))
     (lambda (directory)
       (define-values (out problem) (run (build-path directory "root.agc")))
       (check-equal? (diagnostic-code problem) 'RUNTIME-DIVISION-BY-ZERO)
       (check-equal? (source-position-line (source-span-start (diagnostic-span problem))) 2)
       (check-equal? (source-name (source-span-source (diagnostic-span problem)))
                     (path->string (build-path directory "a.agc"))))))

  (test-case "imported task callbacks keep the execution budget"
    (with-files
     '(("root.agc" . "import \"worker\" as Worker\ndef main() -> Void\n  task = Task.spawn(&Worker.run, 0)\n  IO.inspect(Task.await(task))\nend\n\n")
       ("worker.agc" . "export def run(n: Int) -> Int\n  while n < 100\n    n = n + 1\n  end\n  return n\nend\n\n"))
     (lambda (directory)
       (define-values (out result) (run (build-path directory "root.agc")))
       (check-equal? out "100\n")
       (check-equal? result (void))
       (define-values (limited-out problem) (run (build-path directory "root.agc") #:max-steps 30))
       (check-equal? (diagnostic-code problem) 'RUNTIME-STEP-LIMIT))))

  (test-case "BDD can register imported handlers"
    (with-files
     '(("steps.agc" . "import \"assertions\" as Assertions\ndef main() -> Void\n  BDD.step(\"it works\", &Assertions.verify)\nend\n\n")
       ("assertions.agc" . "import \"std/queue\" as Queue\nexport def verify(args: List[String]) -> Void\n  q = Queue.push(Queue.new(), \"imported handler\")\n  BDD.assert(Result.unwrap!(Queue.peek(q)) == \"imported handler\", \"imported handler\")\nend\n\n")
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
     '(("option.agc" . "export enum Option[T]\n  Some(T)\n  None\nend\n\n")
       ("root.agc" . "import \"option\" as Domain\ndef main() -> Void\n  value: Domain.Option[Int] = Domain.Option.Some(7)\n  case value do\n    Domain.Option.Some(item) ->\n      puts(String.from_int(item))\n    Domain.Option.None ->\n      puts(\"empty\")\n  end\n  empty: Domain.Option[String] = Domain.Option.None()\n  case empty do\n    Domain.Option.Some(item) ->\n      puts(item)\n    Domain.Option.None ->\n      puts(\"none\")\n  end\nend\n\n"))
     (lambda (directory)
       (define-values (out result) (run (build-path directory "root.agc")))
       (check-equal? out "7\nnone\n")
       (check-equal? result (void)))))

  (test-case "private imported enums remain inaccessible"
    (with-files
     '(("option.agc" . "enum Option[T]\n  Some(T)\nend\n\n")
       ("root.agc" . "import \"option\" as Domain\ndef main() -> Void\n  value: Domain.Option[Int] = Domain.Option.Some(1)\nend\n\n"))
     (lambda (directory)
       (define problem (checked (build-path directory "root.agc")))
       (check-equal? (diagnostic-code problem) 'CHECK-IMPORT-NAME)))))
