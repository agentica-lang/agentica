#lang racket

;; The cases that run programs through the CLI are in tests/test_modules.py; these call the modules and the checker.
(require (except-in rackunit check)
         "../src/modules.rkt" "../src/checker.rkt"
         "../src/diagnostic.rkt" "../src/source.rkt")

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

(module+ test
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

  (test-case "imported structs and enums print their declared names"
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
       (check-equal? (diagnostic-code problem) 'CHECK-IMPORT-NAME))))

  (test-case "cycles and dependency runtime failures retain original file spans"
    (with-files
     '(("root.agc" . "import A from \"a\"\ndef main() -> Void\nend\n\n")
       ("a.agc" . "import Root from \"root\"\n"))
     (lambda (directory)
       (define problem (checked (build-path directory "root.agc")))
       (check-equal? (diagnostic-code problem) 'CHECK-IMPORT-CYCLE)
       (check-equal? (source-name (source-span-source (diagnostic-span problem)))
                     (path->string (build-path directory "a.agc"))))))

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
         (check-equal? (diagnostic-code (checked (build-path directory "root.agc"))) 'CHECK-REDEFINED-NAME name))))))

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
