#lang racket

(require (except-in rackunit check) racket/runtime-path json
         "../src/modules.rkt" "../src/checker.rkt"
         "../src/diagnostic.rkt" "../src/source.rkt" "cli-in-process.rkt")

(define-runtime-path main-file "../src/main.rkt")
(define-runtime-path example "../examples/json-modules.agc")

(for ([name '(#"AGENTICA_VM_TRACE" #"AGENTICA_VM_TRACE_FILE" #"AGENTICA_FLUSH_TIMEOUT_MS")])
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

(define (run-with-errors path #:max-steps [steps #f])
  (define program (checked path))
  (when (diagnostic? program) (error 'modules-test "~a" (format-diagnostic program)))
  (define result
    (apply run-main-in-process
           (append '("--json") (if steps (list "--max-steps" (number->string steps)) '())
                   (list (path->string path)))))
  (define errors (third result))
  (values (second result)
          (if (zero? (first result)) (void) (string->jsexpr (last (string-split errors "\n"))))
          errors))

(define (run path #:max-steps [steps #f])
  (define-values (out result errors) (run-with-errors path #:max-steps steps))
  (values out result))

(module+ test
  (test-case "methods work on values whose types come from another file"
    (with-files
     '(("lib.agc" . "export struct Box\n  label: String\nend\n\nexport def make(text: String) -> Box\n  return Box(label: text)\nend\n\n")
       ("root.agc" . "import Lib from \"lib\"\ndef main() -> Void\n  b = Lib.make(\" hi \")\n  IO.inspect(b.label.strip.upcase.size)\nend\n\n"))
     (lambda (directory)
       (define-values (out result) (run (build-path directory "root.agc")))
       (check-equal? out "2\n"))))

  (test-case "blocks in an imported file call that file's private helpers and types"
    (with-files
     '(("lib.agc" . "struct Pair\n  n: Int\nend\n\nexport def doubled(xs: List[Int]) -> List[Int]\n  pairs = xs.map do |x| Pair(n: twice(x)) end\n  return pairs.map do |p: Pair| p.n end\nend\n\ndef twice(n: Int) -> Int\n  return n * 2\nend\n\n")
       ("root.agc" . "import Lib from \"lib\"\ndef main() -> Void\n  IO.inspect(Lib.doubled([1, 2]))\nend\n\n"))
     (lambda (directory)
       (define-values (out result) (run (build-path directory "root.agc")))
       (check-equal? out "[2, 4]\n"))))

  (test-case "interpolation in an imported function reaches that file's private helpers"
    (with-files
     '(("lib.agc" . "export def label(n: Int) -> String\n  return \"n=#{twice(n)}\"\nend\n\ndef twice(n: Int) -> Int\n  return n * 2\nend\n\n")
       ("root.agc" . "import Lib from \"lib\"\ndef main() -> Void\n  puts(Lib.label(3))\nend\n\n"))
     (lambda (directory)
       (define-values (out result) (run (build-path directory "root.agc")))
       (check-equal? out "n=6\n"))))

  (test-case "embedded String queue preserves FIFO and old values without local std files"
    (with-files
     '(("std/queue.agc" . "this local file must not be loaded\n")
       ("root.agc" . "import Queue from \"std/queue\"\nimport Again from \"std/queue\"\ndef main() -> Void\n  original = Queue.new()\n  q: Again.QueueState = Queue.push(original, \"\")\n  q = Queue.push(q, \"same\")\n  q = Queue.push(q, \"same\")\n  IO.inspect(Queue.size(q))\n  IO.inspect(Queue.empty?(original))\n  IO.inspect(not Result.ok?(Queue.pop(original)))\n  IO.inspect(not Result.ok?(Queue.peek(original)))\n  IO.inspect(Result.unwrap!(Queue.peek(q)))\n  while not Queue.empty?(q)\n    item = Result.unwrap!(Queue.pop(q))\n    puts(item.value)\n    q = item.remaining\n  end\n  IO.inspect(Queue.size(q))\nend\n\n"))
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
     '(("root.agc" . "import Value from \"pkg/value\"\ndef main() -> Void\n  puts(Value.read())\nend\n\n")
       ("agc_libs/value.agc" . "export def read() -> String\n  return \"project\"\nend\n\n")
       ("first/value.agc" . "import Helper from \"helper\"\nexport def read() -> String\n  return Helper.read()\nend\n\n")
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
       (list (cons "root.agc" (format "import Q from ~s\ndef main() -> Void\nend\n\n" (car entry))))
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
     '(("root.agc" . "import Value from \"pkg/value\"\ndef main() -> Void\nend\n\n")
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
       ("library/outer.agc" . "import Models from \"models\"\nexport def make(n: Int) -> Models.Value\n  return Models.Value(n: n)\nend\n\n")
       ("root.agc" . "import First from \"library/models\"\nimport Second from \"library/../library/models\"\nimport Outer from \"library/outer\"\ndef main() -> Void\n  value: Second.Value = Outer.make(42)\n  IO.inspect(First.read(value))\n  IO.inspect(Second.read(First.Value(n: 7)))\nend\n\n"))
     (lambda (directory)
       (define-values (out result) (run (build-path directory "root.agc")))
       (check-equal? out "42\n7\n")
       (check-equal? result (void)))))

  (test-case "private helpers and same names in different modules stay separate"
    (with-files
     '(("a.agc" . "export def apply(n: Int) -> Int\n  return helper(n)\nend\n\ndef helper(n: Int) -> Int\n  return n + 1\nend\n\n")
       ("b.agc" . "export def apply(n: Int) -> Int\n  return helper(n)\nend\n\ndef helper(n: Int) -> Int\n  return n + 10\nend\n\n")
       ("root.agc" . "import A from \"a\"\nimport B from \"b\"\ndef main() -> Void\n  IO.inspect(List.map([1, 2], &A.apply))\n  IO.inspect(List.map([1, 2], &B.apply))\nend\n\n"))
     (lambda (directory)
       (define-values (out result) (run (build-path directory "root.agc")))
       (check-equal? out "[2, 3]\n[11, 12]\n")
       (check-equal? result (void)))))

  (test-case "imported structs and enums print their declared names"
    (with-files
     '(("a.agc" . "export struct Point\n  x: Int\nend\n\nexport enum Shape\n  Dot(Point)\n  Empty\nend\n\nexport def show() -> Void\n  puts(\"#{Point(x: 2)} #{Shape.Empty}\")\nend\n\n")
       ("b.agc" . "export struct Point\n  y: Int\nend\n\n")
       ("root.agc" . "import A from \"a\"\nimport B from \"b\"\n\nstruct Both\n  a: A.Point\n  b: B.Point\nend\n\ndef main() -> Void\n  A.show()\n  p = A.Point(x: 3)\n  puts(p)\n  puts(B.Point(y: 4).inspect)\n  puts([A.Shape.Dot(p)].to_s)\n  puts({\"k\": ok(A.Shape.Empty)})\n  IO.warn(p)\n  IO.warn(JSON.schema(Both))\nend\n\n"))
     (lambda (directory)
       (define-values (out result err) (run-with-errors (build-path directory "root.agc")))
       (check-equal? result (void))
       (check-equal? out
                     (string-append "Point(x: 2) Shape.Empty\nPoint(x: 3)\nPoint(y: 4)\n"
                                    "[Shape.Dot(Point(x: 3))]\n{\"k\": ok(Shape.Empty)}\n"))
       (define warnings (string-split err "\n"))
       (check-equal? (car warnings) "Point(x: 3)")
       (check-equal? (hash-count (hash-ref (string->jsexpr (cadr warnings)) '$defs)) 2)))
    (with-files
     '(("a.agc" . "export struct Point\n  x: Int\nend\n\n")
       ("root.agc" . "import A from \"a\"\ndef main() -> Void\n  n: Int = A.Point(x: 1)\nend\n\n"))
     (lambda (directory)
       (define problem (checked (build-path directory "root.agc")))
       (check-equal? (diagnostic-code problem) 'CHECK-TYPE-MISMATCH)
       (check-equal? (diagnostic-actual problem) "Point")))
    (with-files
     '(("a.agc" . "export struct Point\n  x: Int\nend\n\nexport def make(x: Int) -> Point\n  return Point(x: x)\nend\n\n")
       ("root.agc" . "import A from \"a\"\ndef main() -> Void\n  n = A.Point(x: 1).z\nend\n\n")
       ("arity.agc" . "import A from \"a\"\ndef main() -> Void\n  p = A.make()\nend\n\n"))
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
       ("calls.agc" . "export def go() -> Int\n  return helpr()\nend\n\ndef helper() -> Int\n  return 1\nend\n\n")
       ("types.agc" . "import B from \"bad\"\ndef main() -> Void\nend\n\n")
       ("funcs.agc" . "import C from \"calls\"\n\ndef helpe() -> Int\n  return 2\nend\n\ndef main() -> Void\n  n = C.go()\nend\n\n"))
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
           '(("import Missing from \"missing\"\n" "" CHECK-IMPORT-IO)
             ("import M from \"module\"\n" "  M.hidden()\n" CHECK-IMPORT-NAME)
             ("import M from \"module\"\n" "  x = M.Secret(value: 1)\n" CHECK-IMPORT-NAME)
             ("import M from \"module\"\nimport M from \"module\"\n" "" CHECK-REDEFINED-NAME)
             ("import JSON from \"module\"\n" "" CHECK-REDEFINED-NAME)
             ("import Channel from \"module\"\n" "" CHECK-REDEFINED-NAME)
             ("import Set from \"module\"\n" "" CHECK-REDEFINED-NAME)
             ("import Await from \"module\"\n" "" CHECK-REDEFINED-NAME)
             ("import M from \"module.txt\"\n" "" CHECK-IMPORT-PATH)
             ("" "  x = String.nope(\"a\")\n" CHECK-UNKNOWN-NAME)
             ("" "  x = Mpa.put(1)\n" CHECK-UNKNOWN-NAME)
             ("" "  x = IO.nope()\n" CHECK-UNKNOWN-NAME)
             ("" "  x: Missing.Value = 1\n" CHECK-IMPORT-NAME))])
      (with-files
       (list (cons "module.agc" "struct Secret\n  value: Int\nend\n\nexport struct Public\nend\n\ndef hidden() -> Void\nend\n\n")
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
       ("app/root.agc" . "import Util from \"../lib/util\"\ndef main() -> Void\n  puts(Util.read())\nend\n\n"))
     (lambda (directory)
       (define-values (out result) (run (build-path directory "app" "root.agc")))
       (check-equal? out "util\n")))
    (for ([entry '(("lib/util.agc" "import Util from \"lib/util\"")
                   ("std/queue.agc" "import Util from \"std/queue\"")
                   ("lib/util.rb" "import Util from \"lib/util\" to load lib/util.agc")
                   ("a\"b.agc" "import Util from \"a\\\"b\"")
                   ("json.tools.agc" #f)
                   ("lib/" #f) (".." #f) ("." #f)
                   ("" #f))])
      (with-files
       (list (cons "lib/util.agc" "export def read() -> String\n  return \"util\"\nend\n\n")
             (cons "root.agc" (format "# two comment lines keep the import off line 1\n# so the span is not the file start\n\nimport Util from ~s\ndef main() -> Void\nend\n\n" (car entry))))
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
       ("root.agc" . "import S from \"shapes\"\n\nenum Command\n  Show\n  Add(Int)\nend\n\ndef main() -> Void\n  c = Command.Show\n  case c\n    Command.Show -> puts(\"show\")\n    Command.Add(n) -> puts(n.to_s)\n  end\n  s = S.Shape.Dot\n  case s\n    S.Shape.Dot -> puts(\"dot\")\n    _ -> puts(\"other\")\n  end\nend\n\n"))
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

  (test-case "a struct update follows the rules of construction across files"
    ;; An exported struct can be updated by an importer; a module may update its own private structs.
    (with-files
     '(("lib.agc" . "export struct Box\n  label: String\n  size: Int\nend\n\nstruct Hidden\n  n: Int\nend\n\nexport def make() -> Box\n  return Box(label: \"a\", size: 1)\nend\n\nexport def grow(b: Box) -> Box\n  return b.with(size: b.size + 1)\nend\n\nexport def hidden() -> Hidden\n  return Hidden(n: 1).with(n: 2)\nend\n\n")
       ("root.agc" . "import Lib from \"lib\"\n\ndef main() -> Void\n  b = Lib.make().with(label: \"b\")\n  puts(Lib.grow(b))\n  puts(Lib.hidden().n)\nend\n\n"))
     (lambda (directory)
       (define-values (out result) (run (build-path directory "root.agc")))
       (check-equal? out "Box(label: \"b\", size: 2)\n2\n")))
    ;; A value of a struct the other module keeps private cannot be updated: the diagnostic of constructing it.
    (with-files
     '(("lib.agc" . "struct Hidden\n  n: Int\nend\n\nexport def hidden() -> Hidden\n  return Hidden(n: 1)\nend\n\n")
       ("root.agc" . "import Lib from \"lib\"\n\ndef main() -> Void\n  h = Lib.hidden()\n  x = h.with(n: 2)\nend\n\n"))
     (lambda (directory)
       (define problem (checked (build-path directory "root.agc")))
       (check-equal? (diagnostic-code problem) 'CHECK-IMPORT-NAME)
       (check-equal? (source-position-line (source-span-start (diagnostic-span problem))) 5)
       (check-equal? (source-position-column (source-span-start (diagnostic-span problem))) 7)))
    ;; Importing a module that only passes the struct along is not enough: the importer needs the struct's own module.
    (with-files
     '(("a.agc" . "export struct P\n  n: Int\nend\n\n")
       ("b.agc" . "import A from \"a\"\n\nexport def get() -> A.P\n  return A.P(n: 1)\nend\n\n")
       ("root.agc" . "import B from \"b\"\n\ndef main() -> Void\n  x = B.get().with(n: 2)\nend\n\n"))
     (lambda (directory)
       (define problem (checked (build-path directory "root.agc")))
       (check-equal? (diagnostic-code problem) 'CHECK-IMPORT-NAME)))
    ;; A builtin record of std/http is updated without importing a module that declares it (the form that phase 19 teaches).
    (with-files
     '(("root.agc" . "import Http from \"std/http\"\n\ndef main() -> Void\n  o = Http.client_options()\n  p = o.with(timeout_ms: 5000, ca_file: \"ca.pem\")\n  puts(p.timeout_ms)\n  puts(o.timeout_ms)\nend\n\n"))
     (lambda (directory)
       (define-values (out result) (run (build-path directory "root.agc")))
       (check-equal? out "5000\n30000\n")))
    ;; Alias.with(...) is a call of the module's function named with, not an update.
    (with-files
     '(("lib.agc" . "export def with(n: Int) -> Int\n  return n + 1\nend\n\n")
       ("root.agc" . "import Lib from \"lib\"\n\ndef main() -> Void\n  puts(Lib.with(1))\nend\n\n"))
     (lambda (directory)
       (define-values (out result) (run (build-path directory "root.agc")))
       (check-equal? out "2\n"))))

  (test-case "cycles and dependency runtime failures retain original file spans"
    (with-files
     '(("root.agc" . "import A from \"a\"\ndef main() -> Void\nend\n\n")
       ("a.agc" . "import Root from \"root\"\n"))
     (lambda (directory)
       (define problem (checked (build-path directory "root.agc")))
       (check-equal? (diagnostic-code problem) 'CHECK-IMPORT-CYCLE)
       (check-equal? (source-name (source-span-source (diagnostic-span problem)))
                     (path->string (build-path directory "a.agc")))))
    (with-files
     '(("root.agc" . "import A from \"a\"\ndef main() -> Void\n  IO.inspect(A.fail(0))\nend\n\n")
       ("a.agc" . "export def fail(n: Int) -> Int\n  return 1 / n\nend\n\n"))
     (lambda (directory)
       (define-values (out problem) (run (build-path directory "root.agc")))
       (check-equal? (hash-ref problem 'code) "RUNTIME-DIVISION-BY-ZERO")
       (check-equal? (hash-ref (hash-ref (hash-ref problem 'range) 'start) 'line) 2)
       (check-equal? (hash-ref problem 'file) (path->string (build-path directory "a.agc"))))))

  (test-case "imported task callbacks keep the execution budget"
    (with-files
     '(("root.agc" . "import Worker from \"worker\"\ndef main() -> Void\n  task = Task.spawn(&Worker.run, 0)\n  IO.inspect(Task.await(task))\nend\n\n")
       ("worker.agc" . "export def run(n: Int) -> Int\n  while n < 100\n    n = n + 1\n  end\n  return n\nend\n\n"))
     (lambda (directory)
       (define-values (out result) (run (build-path directory "root.agc")))
       (check-equal? out "100\n")
       (check-equal? result (void))
       (define-values (limited-out problem) (run (build-path directory "root.agc") #:max-steps 30))
       (check-equal? (hash-ref problem 'code) "RUNTIME-STEP-LIMIT"))))

  (test-case "a BDD step program imports its handlers, which share std/bdd"
    (with-files
     '(("steps.agc" . "import BDD from \"std/bdd\"\nimport Assertions from \"assertions\"\n\ndef main() -> Void\n  BDD.run([BDD.step(\"it works\", &Assertions.verify)])\nend\n\n")
       ("assertions.agc" . "import Spec from \"std/bdd\"\nimport Queue from \"std/queue\"\n\nexport def verify(ctx: Spec.Context, args: List[String]) -> Spec.Context\n  q = Queue.push(Queue.new(), \"imported handler\")\n  return Spec.assert(ctx, Result.unwrap!(Queue.peek(q)) == \"imported handler\", \"imported handler\")\nend\n\n")
       ("test.feature" . "Feature: Modules\nScenario: Imported handler\nThen it works\n"))
     (lambda (directory)
       (define executable (getenv "AGENTICA_TEST_EXECUTABLE"))
       (define arguments (list "test" "--json" (path->string (build-path directory "test.feature"))
                               "--steps" (path->string (build-path directory "steps.agc"))))
       (define-values (process output input errors)
         (if executable
             (apply subprocess #f #f #f executable arguments)
             (apply subprocess #f #f #f (find-system-path 'exec-file) main-file arguments)))
       (close-output-port input)
       (define drained (thread (lambda () (port->string errors))))
       (define report (string->jsexpr (port->string output)))
       (thread-wait drained)
       (close-input-port output)
       (close-input-port errors)
       (subprocess-wait process)
       (check-equal? (subprocess-status process) 0)
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
       ("root.agc" . "import Domain from \"option\"\ndef main() -> Void\n  value: Domain.Option[Int] = Domain.Option.Some(7)\n  case value do\n    Domain.Option.Some(item) ->\n      puts(String.from_int(item))\n    Domain.Option.None ->\n      puts(\"empty\")\n  end\n  empty: Domain.Option[String] = Domain.Option.None()\n  case empty do\n    Domain.Option.Some(item) ->\n      puts(item)\n    Domain.Option.None ->\n      puts(\"none\")\n  end\nend\n\n"))
     (lambda (directory)
       (define-values (out result) (run (build-path directory "root.agc")))
       (check-equal? out "7\nnone\n")
       (check-equal? result (void)))))

  (test-case "private imported enums remain inaccessible"
    (with-files
     '(("option.agc" . "enum Option[T]\n  Some(T)\nend\n\n")
       ("root.agc" . "import Domain from \"option\"\ndef main() -> Void\n  value: Domain.Option[Int] = Domain.Option.Some(1)\nend\n\n"))
     (lambda (directory)
       (define problem (checked (build-path directory "root.agc")))
       (check-equal? (diagnostic-code problem) 'CHECK-IMPORT-NAME))))

  (test-case "the removed std/http server calls point to handlers that return an HttpResponse"
    (for ([entry '(("  HTTP.respond(1, 200, [], \"hi\", 1000)\n" CHECK-IMPORT-NAME #rx"return ok\\(HttpResponse")
                   ("  HTTP.finish(1, [], 1000)\n" CHECK-IMPORT-NAME #rx"return ok\\(HttpResponse")
                   ("  HTTP.nothing(1)\n" CHECK-IMPORT-NAME #f))])
      (with-files
       (list (cons "root.agc" (string-append "import HTTP from \"std/http\"\ndef main() -> Void\n" (car entry) "end\n\n")))
       (lambda (directory)
         (define problem (checked (build-path directory "root.agc")))
         (check-equal? (diagnostic-code problem) (cadr entry) (car entry))
         (if (caddr entry)
             (check-regexp-match (caddr entry) (diagnostic-help problem))
             (check-false (diagnostic-help problem)))))))

  (test-case "a wrong imported name suggests the closest export, never a private name"
    (for ([entry '(("  x = M.publc()\n" #rx"\"public\"")
                   ("  x = M.Publik(a: 1)\n" #rx"\"Public\"")
                   ("  x: M.Publc = nil\n" #rx"\"Public\"")
                   ;; `hidden` and `Secret` exist but are private; `faraway` is not close to anything.
                   ("  x = M.hiden()\n" #f)
                   ("  x = M.Secret(value: 1)\n" #f)
                   ("  x = M.faraway()\n" #f))])
      (with-files
       (list (cons "module.agc" "struct Secret\n  value: Int\nend\n\nexport struct Public\n  a: Int\nend\n\nexport def public() -> Void\nend\n\ndef hidden() -> Void\nend\n\n")
             (cons "root.agc" (string-append "import M from \"module\"\ndef main() -> Void\n" (car entry) "end\n\n")))
       (lambda (directory)
         (define problem (checked (build-path directory "root.agc")))
         (check-equal? (diagnostic-code problem) 'CHECK-IMPORT-NAME (car entry))
         (check-equal? (source-position-line (source-span-start (diagnostic-span problem))) 3)
         (if (cadr entry)
             (check-regexp-match (cadr entry) (diagnostic-help problem))
             (check-false (diagnostic-help problem))))))
    ;; `ab` and `ac` are both one edit from `ad`; the tie goes to the smaller name.
    (with-files
     '(("module.agc" . "export def ac() -> Void\nend\n\nexport def ab() -> Void\nend\n\n")
       ("root.agc" . "import M from \"module\"\ndef main() -> Void\n  M.ad()\nend\n\n"))
     (lambda (directory)
       (define problem (checked (build-path directory "root.agc")))
       (check-equal? (diagnostic-code problem) 'CHECK-IMPORT-NAME)
       (check-regexp-match #rx"\"ab\"" (diagnostic-help problem)))))

  (test-case "the std/http and std/logger helps win over the generic suggestion, which works on std modules"
    (with-files
     '(("root.agc" . "import HTTP from \"std/http\"\ndef main() -> Void\n  x = HTTP.gett(\"u\")\nend\n\n"))
     (lambda (directory)
       (define problem (checked (build-path directory "root.agc")))
       (check-equal? (diagnostic-code problem) 'CHECK-IMPORT-NAME)
       (check-regexp-match #rx"\"get\"" (diagnostic-help problem))))
    (with-files
     '(("root.agc" . "import Logger from \"std/logger\"\ndef main() -> Void\n  Logger.warnin(\"x\")\nend\n\n"))
     (lambda (directory)
       (define problem (checked (build-path directory "root.agc")))
       (check-equal? (diagnostic-code problem) 'CHECK-IMPORT-NAME)
       (check-regexp-match #rx"\"warning\"" (diagnostic-help problem)))))

  (test-case "LogRegistry is internal to std/logger, its types are reserved, and Logger has no error"
    (with-files
     '(("root.agc" . "def main() -> Void\n  x = LogRegistry.level()\nend\n\n"))
     (lambda (directory)
       (define problem (checked (build-path directory "root.agc")))
       (check-equal? (diagnostic-code problem) 'CHECK-UNKNOWN-NAME)
       (check-regexp-match #rx"import Logger from \"std/logger\"" (diagnostic-help problem))
       (check-false (regexp-match? #rx"std/http" (diagnostic-help problem)))))
    (for ([declaration '("struct LogEvent\n  n: Int\nend\n\n" "enum LogLevel\n  Loud\nend\n\n" "struct LogRegistry\n  n: Int\nend\n\n")])
      (with-files
       (list (cons "root.agc" (string-append declaration "def main() -> Void\nend\n\n")))
       (lambda (directory)
         (check-equal? (diagnostic-code (checked (build-path directory "root.agc"))) 'CHECK-REDEFINED-NAME declaration))))
    (with-files
     '(("root.agc" . "import Logger from \"std/logger\"\ndef main() -> Void\n  Logger.error(\"x\")\nend\n\n"))
     (lambda (directory)
       (define problem (checked (build-path directory "root.agc")))
       (check-equal? (diagnostic-code problem) 'CHECK-IMPORT-NAME)
       (check-regexp-match #rx"Logger\\.err" (diagnostic-help problem))))
    (with-files
     '(("root.agc" . "import Logger from \"std/logger\"\ndef main() -> Void\n  Logger.err(\"x\")\n  level: LogLevel = Logger.level()\n  event = LogEvent(level: level, message: \"m\", fields: {}, time_ms: 0, task: 1)\n  Logger.stderr_text(event)\nend\n\n"))
     (lambda (directory)
       (check-false (diagnostic? (checked (build-path directory "root.agc")))))))

  (test-case "HttpWire is internal to std/http: user files, relative imports and pkg modules cannot call it"
    (define call "export def go() -> Void\n  HttpWire.client(1, 1, 1, 1, \"\")\nend\n\n")
    (for ([entry `(("root.agc" "import Wire from \"pkg/wire\"\ndef main() -> Void\n  HttpWire.close_client(HttpWire.client(1, 1, 1, 1, \"\"))\nend\n\n")
                   ("lib.agc" "import Lib from \"lib\"\ndef main() -> Void\n  Lib.go()\nend\n\n")
                   ("libs/wire.agc" "import Wire from \"pkg/wire\"\ndef main() -> Void\n  Wire.go()\nend\n\n"))])
      (with-files
       (list (cons "root.agc" (cadr entry)) (cons "lib.agc" call) (cons "libs/wire.agc" call))
       (lambda (directory)
         (define env (environment-variables-copy (current-environment-variables)))
         (environment-variables-set! env #"AGENTICA_PATH" (path->bytes (build-path directory "libs")))
         (define problem (parameterize ([current-environment-variables env])
                           (checked (build-path directory "root.agc"))))
         (check-equal? (diagnostic-code problem) 'CHECK-UNKNOWN-NAME (car entry))
         (check-equal? (source-name (source-span-source (diagnostic-span problem)))
                       (path->string (build-path directory (car entry))))
         (check-regexp-match #rx"import HTTP from \"std/http\"" (diagnostic-help problem)))))
    (with-files
     '(("root.agc" . "import HTTP from \"std/http\"\ndef main() -> Void\n  HTTP.close_client(Result.unwrap!(HTTP.client(HTTP.client_options())))\nend\n\n"))
     (lambda (directory)
       (check-false (diagnostic? (checked (build-path directory "root.agc"))))))
    (for ([body '("  x = HttpWir.client(1)\n" "  x = close_clien(1)\n" "  x = HTTP.exchang(1)\n")])
      (with-files
       (list (cons "root.agc" (string-append "import HTTP from \"std/http\"\ndef main() -> Void\n" body "end\n\n")))
       (lambda (directory)
         (define problem (checked (build-path directory "root.agc")))
         (check-true (diagnostic? problem) body)
         (check-false (regexp-match? #rx"HttpWire" (or (diagnostic-help problem) "")) body))))
    (for ([name '("HttpWire" "HttpResponse" "HttpRequest" "HttpServer" "HttpServerOptions")])
      (with-files
       (list (cons "root.agc" (format "struct ~a\n  n: Int\nend\n\ndef main() -> Void\nend\n\n" name)))
       (lambda (directory)
         (check-equal? (diagnostic-code (checked (build-path directory "root.agc"))) 'CHECK-REDEFINED-NAME name))))
    (for ([arguments '(("help" "HttpWire.client") ("help" "HttpWire.exchange" "--json") ("help" "HttpWire.clien"))])
      (define-values (process output input errors)
        (apply subprocess #f #f #f (find-system-path 'exec-file) main-file arguments))
      (close-output-port input)
      (define text (port->string errors))
      (close-input-port output)
      (subprocess-wait process)
      (close-input-port errors)
      (check-equal? (subprocess-status process) 2 (format "~a" arguments))
      (check-equal? text (format "agentica: unknown builtin ~a\n" (cadr arguments))))))

(module+ test
  (define (order-problem files)
    (with-files files
      (lambda (directory)
        (define problem (checked (build-path directory "root.agc")))
        (and (diagnostic? problem)
             (let ([span (diagnostic-span problem)])
               (list (diagnostic-code problem)
                     (path->string (file-name-from-path (source-name (source-span-source span))))
                     (source-position-line (source-span-start span))
                     (source-position-column (source-span-start span))))))))

  (test-case "a type after a function is out of order, at the type"
    (check-equal?
     (order-problem '(("root.agc" . "def main() -> Void\nend\n\nstruct Late\n  n: Int\nend\n\n")))
     '(CHECK-DECL-ORDER "root.agc" 4 1)))

  (test-case "a private function before an exported one is out of order, at the export"
    (check-equal?
     (order-problem '(("root.agc" . "def helper() -> Void\nend\n\nexport def api() -> Void\nend\n\n")))
     '(CHECK-DECL-ORDER "root.agc" 4 1))
    (check-equal?
     (order-problem '(("root.agc" . "def helper() -> Void\nend\n\nexport struct Late\nend\n\n")))
     '(CHECK-DECL-ORDER "root.agc" 4 1)))

  (test-case "a private enum after a function is out of order, at the enum"
    (check-equal?
     (order-problem '(("root.agc" . "def main() -> Void\nend\n\nenum Late\n  A\nend\n\n")))
     '(CHECK-DECL-ORDER "root.agc" 4 1)))

  (test-case "an import after a declaration is out of order"
    (check-equal?
     (order-problem '(("lib.agc" . "export def go() -> Void\nend\n\n")
                      ("root.agc" . "struct Early\nend\n\nimport Lib from \"lib\"\n")))
     '(CHECK-DECL-ORDER "root.agc" 4 1)))

  (test-case "types in any order, then exports, then private functions, check clean"
    (with-files
     '(("lib.agc" . "export def go() -> Void\nend\n\n")
       ("root.agc" . "## Module doc.\n\nimport Lib from \"lib\"\nimport Queue from \"std/queue\"\n\nexport enum Kind\n  A\nend\n\nstruct Box\n  n: Int\nend\n\nexport struct Pair\n  n: Int\nend\n\nenum Hidden\n  B\nend\n\nexport def api() -> Void\n  Lib.go()\n  helper()\nend\n\ndef helper() -> Void\nend\n\ndef main() -> Void\nend\n\n"))
     (lambda (directory)
       (check-false (diagnostic? (checked (build-path directory "root.agc")))))))

  (test-case "an imported module is checked too, and the diagnostic names its file"
    (check-equal?
     (order-problem '(("lib.agc" . "def helper() -> Void\nend\n\nexport def go() -> Void\nend\n\n")
                      ("root.agc" . "import Lib from \"lib\"\ndef main() -> Void\n  Lib.go()\nend\n\n")))
     '(CHECK-DECL-ORDER "lib.agc" 4 1)))

  (test-case "embedded std modules follow the rule, so importing them never trips it"
    (for ([name '("std/http" "std/logger" "std/binary" "std/toml" "std/queue")])
      (with-files
       (list (cons "root.agc" (format "import M from ~s\ndef main() -> Void\nend\n\n" name)))
       (lambda (directory)
         (check-false (diagnostic? (checked (build-path directory "root.agc"))) name))))))
