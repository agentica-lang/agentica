#lang racket

(require (except-in rackunit check)
         "../src/checker.rkt"
         "../src/builtins.rkt"
         "../src/diagnostic.rkt"
         "../src/evaluator.rkt"
         "../src/lexer.rkt"
         "../src/parser.rkt"
         "../src/source.rkt")

(define (run text)
  (define lexed (lex (source "test.agc" text)))
  (define parsed (if (diagnostic? lexed) lexed (parse lexed)))
  (define checked (if (diagnostic? parsed) parsed (check parsed)))
  (when (diagnostic? checked)
    (error 'evaluator-test "program rejected before running: ~a" (format-diagnostic checked)))
  (define result #f)
  (define output (with-output-to-string (lambda () (set! result (evaluate checked)))))
  (values output result))

(define (output-of text)
  (define-values (output result) (run text))
  (when (diagnostic? result)
    (error 'evaluator-test "unexpected diagnostic: ~a" (format-diagnostic result)))
  output)

(define (run-io text [input ""] [arguments '()] #:max-steps [max-steps #f])
  (define lexed (lex (source "test.agc" text)))
  (define parsed (if (diagnostic? lexed) lexed (parse lexed)))
  (define checked (if (diagnostic? parsed) parsed (check parsed)))
  (when (diagnostic? checked)
    (error 'evaluator-test "program rejected before running: ~a" (format-diagnostic checked)))
  (define out (open-output-string))
  (define err (open-output-string))
  (define result (evaluate checked
                           #:in (if (bytes? input) (open-input-bytes input) (open-input-string input))
                           #:out out
                           #:err err
                           #:args arguments
                           #:max-steps max-steps))
  (values (get-output-string out) (get-output-string err) result))

(define (diagnostic-of text)
  (define-values (output result) (run text))
  (unless (diagnostic? result)
    (error 'evaluator-test "expected a runtime diagnostic, got ~s" result))
  result)

(define (main-with body)
  (format "def main() -> Nil\n~a\nend\n" body))

(define (position-of problem)
  (define start (source-span-start (diagnostic-span problem)))
  (list (source-position-line start) (source-position-column start)))

(module+ test
  (test-case "the section 8 programs run"
    (check-equal? (output-of "def main() -> Nil\n  puts(\"hello\")\nend\n") "hello\n")
    (check-equal? (output-of (string-append
                              "def classify(age: Int) -> String\n"
                              "  if age >= 18\n    return \"adult\"\n"
                              "  elsif age >= 13\n    return \"teen\"\n"
                              "  else\n    return \"child\"\n  end\nend\n\n"
                              "def main() -> Nil\n"
                              "  puts(classify(25))\n  puts(classify(15))\n  puts(classify(3))\nend\n"))
                  "adult\nteen\nchild\n")
    (check-equal? (output-of (string-append
                              "struct Task\n  title: String\n  done: Bool\nend\n\n"
                              "def main() -> Nil\n"
                              "  tasks: List[Task] = [\n"
                              "    Task(title: \"a\", done: false),\n"
                              "    Task(done: true, title: \"b\"),\n"
                              "    Task(title: \"c\", done: false)\n  ]\n"
                              "  for task in tasks\n    if not task.done\n      puts(task.title)\n    end\n  end\nend\n"))
                  "a\nc\n"))

  (test-case "control flow, scopes, and recursion"
    (check-equal? (output-of (string-append
                              "def fact(n: Int) -> Int\n"
                              "  if n <= 1\n    return 1\n  end\n  return n * fact(n - 1)\nend\n\n"
                              "def find(xs: List[Int], target: Int) -> Int\n"
                              "  for x in xs\n    if x == target\n      return x\n    end\n  end\n  return 0\nend\n\n"
                              "def main() -> Nil\n"
                              "  i = 0\n  total = 0\n"
                              "  while i < 4\n    total = total + i\n    i = i + 1\n  end\n"
                              "  empty: List[Int] = []\n  for e in empty\n    puts(\"never\")\n  end\n"
                              "  if total == 6\n    puts(\"six\")\n  end\n"
                              "  puts(\"ok\")\nend\n"
                              "def unused() -> Nil\n  puts(\"\")\nend\n"))
                  "six\nok\n")
    (check-equal? (output-of (string-append
                              "def fact(n: Int) -> Int\n"
                              "  if n <= 1\n    return 1\n  end\n  return n * fact(n - 1)\nend\n\n"
                              "def main() -> Nil\n  if fact(5) == 120 and later() == 1\n    puts(\"yes\")\n  end\nend\n"
                              "def later() -> Int\n  return 1\nend\n"))
                  "yes\n"))

  (test-case "operators"
    (check-equal? (output-of
                   (string-append
                    "def noisy() -> Bool\n  puts(\"ran\")\n  return true\nend\n\n"
                    "def main() -> Nil\n"
                    "  if false and noisy()\n    puts(\"no\")\n  end\n"
                    "  if true or noisy()\n    puts(\"skip\")\n  end\n"
                    "  a = 0 - 7\n"
                    "  if a / 2 == 0 - 3 and a % 2 == 0 - 1\n    puts(\"trunc\")\n  end\n"
                    "  puts(\"a\" + \"b\")\nend\n"))
                  "skip\ntrunc\nab\n"))

  (test-case "maps are immutable and keep insertion order"
    (check-equal? (output-of
                   (main-with
                    (string-append
                     "  m: Map[String, Int] = {\"b\": 1, \"a\": 2, \"b\": 3}\n"
                     "  n = Map.put(m, \"c\", 4)\n"
                     "  p = Map.put(n, String.downcase(\"B\"), 9)\n"
                     "  for k in Map.keys(p)\n    puts(k)\n  end\n"
                     "  IO.inspect(m)\n  IO.inspect(n)\n  IO.inspect(p)\n"
                     "  if Map.has_key?(m, \"c\") or m[\"b\"] != 3 or n[\"b\"] != 3 or p[\"b\"] != 9 or Map.size(m) != 2 or Map.size(n) != 3 or Map.size(p) != 3 or List.size(Map.keys(p)) != 3\n"
                     "    puts(\"wrong\")\n  end")))
                  "b\na\nc\n{\"b\": 3, \"a\": 2}\n{\"b\": 3, \"a\": 2, \"c\": 4}\n{\"b\": 9, \"a\": 2, \"c\": 4}\n"))

  (test-case "maps preserve empty maps, integer keys, false/nil values, and nested order"
    (check-equal?
     (output-of
      (main-with
       (string-append
        "  empty: Map[Int, Bool] = {}\n"
        "  IO.inspect(empty)\n  IO.inspect(Map.keys(empty))\n  IO.inspect(Map.size(empty))\n"
        "  flags = Map.put(empty, -1, false)\n"
        "  changed = Map.put(flags, 9223372036854775807, true)\n"
        "  changed = Map.put(changed, -1, true)\n"
        "  IO.inspect(flags[-1])\n  IO.inspect(changed[-1])\n"
        "  IO.inspect(Map.has_key?(flags, -1))\n"
        "  IO.inspect(Map.has_key?(flags, 9223372036854775807))\n"
        "  IO.inspect(Map.size(changed))\n  IO.inspect(Map.keys(changed))\n"
        "  nothing: Map[String, Nil] = {\"none\": nil}\n"
        "  IO.inspect(nothing[\"none\"])\n  IO.inspect(Map.has_key?(nothing, \"none\"))\n"
        "  nested: Map[String, Result[Map[String, Int]]] = {\"z\": ok({\"b\": 1, \"a\": 2, \"b\": 3}), \"a\": error(\"bad\")}\n"
        "  IO.inspect(nested)")))
     "{}\n[]\n0\nfalse\ntrue\ntrue\nfalse\n2\n[-1, 9223372036854775807]\nnil\ntrue\n{\"z\": ok({\"b\": 3, \"a\": 2}), \"a\": error(\"bad\")}\n"))

  (test-case "a missing map key is a located diagnostic"
    (for ([body '("  m = {\"a\": 1}\n  x = m[\"z\"]"
                  "  m: Map[Int, Bool] = {}\n  x = m[-1]"
                  "  m = {-1: false}\n  x = m[0]")])
      (define missing (diagnostic-of (main-with body)))
      (check-equal? (diagnostic-code missing) 'RUNTIME-KEY-NOT-FOUND)
      (check-equal? (position-of missing) '(3 9))))

  (test-case "String.slice and number conversions fail with located diagnostics"
    (define past-end (diagnostic-of (main-with "  x = String.slice(\"abc\", 2, 5)")))
    (check-equal? (diagnostic-code past-end) 'RUNTIME-INDEX-OUT-OF-RANGE)
    (check-equal? (diagnostic-code (diagnostic-of (main-with "  x = String.slice(\"abc\", 0 - 1, 1)")))
                  'RUNTIME-INDEX-OUT-OF-RANGE)
    (check-equal? (diagnostic-code (diagnostic-of (main-with "  x = String.to_int!(\"1.5\")")))
                  'RUNTIME-INVALID-NUMBER)
    (check-equal? (diagnostic-code (diagnostic-of (main-with "  x = String.to_int!(\"#x10\")")))
                  'RUNTIME-INVALID-NUMBER)
    (check-equal? (diagnostic-code (diagnostic-of (main-with "  x = String.to_int!(\"9223372036854775808\")")))
                  'RUNTIME-INTEGER-OVERFLOW)
    (check-equal? (diagnostic-code (diagnostic-of (main-with "  x = String.to_float!(\"abc\")")))
                  'RUNTIME-INVALID-NUMBER)
    (check-equal? (diagnostic-code (diagnostic-of (main-with "  x = String.to_float!(\"1+2i\")")))
                  'RUNTIME-INVALID-NUMBER)
    (check-equal? (diagnostic-code (diagnostic-of (main-with "  x = String.to_float!(\"1/2\")")))
                  'RUNTIME-INVALID-NUMBER))

  (test-case "user functions may use ? and ! suffixes"
    (check-equal? (output-of
                   (string-append
                    "def ready?() -> Bool\n  return true\nend\n\n"
                    "def value!() -> String\n  return \"ok\"\nend\n\n"
                    "def main() -> Nil\n"
                    "  if ready?()\n    puts(value!())\n  end\n"
                    "end\n"))
                  "ok\n"))

  (test-case "IO writes to the injected ports and inspect returns its value"
    (define-values (output err result)
      (run-io (main-with
               (string-append
                "  IO.puts(\"a\")\n"
                "  IO.print(\"b\")\n"
                "  IO.warn(\"w\")\n"
                "  x = IO.inspect([1, 2])\n"
                "  puts(String.from_int(List.size(x)))"))))
    (check-equal? result 'nil)
    (check-equal? output "a\nb[1, 2]\n2\n")
    (check-equal? err "w\n"))

  (test-case "IO.inspect prints structs, lists, and maps in a stable form"
    (define-values (output err result)
      (run-io (string-append
               "struct Task\n  title: String\n  done: Bool\nend\n\n"
               "def main() -> Nil\n"
               "  t = Task(done: true, title: \"a\")\n"
               "  IO.inspect(t)\n"
               "  IO.inspect({\"k\": 1})\n"
               "  IO.inspect(\"hi\")\n"
               "  IO.inspect(nil)\n"
               "end\n")))
    (check-equal? result 'nil)
    (check-equal? output "Task(title: \"a\", done: true)\n{\"k\": 1}\n\"hi\"\nnil\n"))

  (test-case "IO.gets! reads lines, IO.read drains, and IO.eof? peeks"
    (define-values (output err result)
      (run-io (main-with
               (string-append
                "  if IO.eof?()\n    puts(\"empty\")\n  end\n"
                "  puts(IO.gets!())\n"
                "  puts(IO.gets!())\n"
                "  puts(IO.read())\n"
                "  if IO.eof?()\n    puts(\"done\")\n  end\n"))
              "one\r\ntwo\rrest\n"))
    (check-equal? result 'nil)
    (check-equal? output "one\ntwo\nrest\n\ndone\n"))

  (test-case "counted reads preserve raw bytes, UTF-8 boundaries, and EOF"
    (define-values (out err result)
      (run-io
       (main-with
        (string-append
         "  IO.inspect(IO.read_bytes(0))\n  IO.inspect(IO.eof?())\n"
         "  first = Result.unwrap!(IO.read_bytes(1))\n  IO.inspect(first)\n"
         "  IO.inspect(Result.ok?(String.from_bytes(first)))\n"
         "  second = Result.unwrap!(IO.read_bytes(1))\n"
         "  IO.inspect(String.from_bytes([first[0], second[0]]))\n"
         "  emoji = Result.unwrap!(IO.read_bytes(4))\n  IO.inspect(String.from_bytes(emoji))\n"
         "  IO.inspect(IO.eof?())\n  IO.inspect(IO.read_bytes(9))\n"
         "  IO.inspect(IO.eof?())\n  IO.inspect(IO.read_bytes(1))"))
       (bytes 195 177 240 159 152 128 255 0)))
    (check-equal? result 'nil)
    (check-equal? err "")
    (check-equal? out "ok([])\nfalse\n[195]\nfalse\nok(\"ñ\")\nok(\"😀\")\nfalse\nok([255, 0])\ntrue\nok([])\n"))

  (test-case "invalid read sizes do not consume input and text reads share the port"
    (define-values (out err result)
      (run-io
       (main-with
        (string-append
         "  for count in [-1, 1048577, 9223372036854775807]\n"
         "    IO.inspect(Result.ok?(IO.read_bytes(count)))\n  end\n"
         "  puts(IO.gets!())\n  IO.inspect(IO.read_bytes(2))\n"
         "  IO.inspect(IO.eof?())\n  puts(IO.read())\n"
         "  IO.inspect(IO.read_bytes(1048576))\n  IO.inspect(IO.read_bytes(0))"))
       "hello\nxyz"))
    (check-equal? result 'nil)
    (check-equal? err "")
    (check-equal? out "false\nfalse\nfalse\nhello\nok([120, 121])\nfalse\nz\nok([])\nok([])\n"))

  (test-case "String.from_bytes validates byte values and decodes UTF-8 strictly"
    (for ([data '("[-1]" "[256]" "[9223372036854775807]" "[195]" "[128]"
                  "[192, 175]" "[237, 160, 128]" "[244, 144, 128, 128]" "[255]")])
      (check-equal?
       (output-of (main-with (format "  IO.inspect(Result.ok?(String.from_bytes(~a)))" data)))
       "false\n" data))
    (check-equal?
     (output-of (main-with "  IO.inspect(String.from_bytes([]))\n  IO.inspect(String.from_bytes([65, 10, 66]))\n  IO.inspect(String.length(Result.unwrap!(String.from_bytes([0]))))"))
     "ok(\"\")\nok(\"A\\nB\")\n1\n"))

  (test-case "IO.gets! at end of input is a located diagnostic"
    (define-values (output err result) (run-io (main-with "  x = IO.gets!()") ""))
    (check-true (diagnostic? result))
    (check-equal? (diagnostic-code result) 'RUNTIME-END-OF-INPUT)
    (check-equal? (position-of result) '(2 7)))

  (test-case "System.args and System.exit"
    (define-values (args-output err args-result)
      (run-io (main-with "  for a in System.args()\n    puts(a)\n  end") "" '("x" "y")))
    (check-equal? args-result 'nil)
    (check-equal? args-output "x\ny\n")
    (define-values (exit-output exit-err result) (run-io (main-with "  System.exit(3)")))
    (check-true (exit-code? result))
    (check-equal? (exit-code-code result) 3))

  (test-case "every catalog entry is typed and dispatched through a real program"
    ;; Independent examples and expected output, not signatures copied from the catalog.
    (define samples
      '(("puts" "puts(\"x\")" "x\nnil\n")
        ("IO.puts" "IO.puts(\"x\")" "x\nnil\n")
        ("IO.print" "IO.print(\"x\")" "xnil\n")
        ("IO.warn" "IO.warn(\"x\")" "nil\n")
        ("IO.inspect" "IO.inspect(7)" "7\n7\n")
        ("IO.gets" "IO.gets()" "ok(\"line\")\n")
        ("IO.gets!" "IO.gets!()" "\"line\"\n")
        ("IO.read" "IO.read()" "\"line\\n\"\n")
        ("IO.read_bytes" "IO.read_bytes(1)" "ok([108])\n")
        ("IO.flush" "IO.flush()" "nil\n")
        ("IO.eof?" "IO.eof?()" "false\n")
        ("System.args" "System.args()" "[\"arg\"]\n")
        ("System.exit" "System.exit(0)" "")
        ("Map.has_key?" "Map.has_key?({\"k\": 1}, \"k\")" "true\n")
        ("Map.keys" "Map.keys({\"k\": 1})" "[\"k\"]\n")
        ("Map.size" "Map.size({\"k\": 1})" "1\n")
        ("Map.put" "Map.put({\"k\": 1}, \"k\", 2)" "{\"k\": 2}\n")
        ("Map.get" "Map.get({\"k\": 1}, \"k\")" "ok(1)\n")
        ("Map.delete" "Map.delete({\"k\": 1}, \"k\")" "{}\n")
        ("Map.values" "Map.values({\"k\": 1})" "[1]\n")
        ("JSON.parse" "JSON.parse(\"null\")" "ok(<Json>)\n")
        ("JSON.encode" "JSON.encode(7)" "\"7\"\n")
        ("JSON.get" "JSON.get(Result.unwrap!(JSON.parse(\"{\\\"k\\\": false}\")), \"k\")" "ok(<Json>)\n")
        ("JSON.at" "JSON.at(Result.unwrap!(JSON.parse(\"[null]\")), 0)" "ok(<Json>)\n")
        ("JSON.string" "JSON.string(Result.unwrap!(JSON.parse(\"\\\"x\\\"\")))" "ok(\"x\")\n")
        ("JSON.int" "JSON.int(Result.unwrap!(JSON.parse(\"7\")))" "ok(7)\n")
        ("JSON.float" "JSON.float(Result.unwrap!(JSON.parse(\"7\")))" "ok(7.0)\n")
        ("JSON.bool" "JSON.bool(Result.unwrap!(JSON.parse(\"false\")))" "ok(false)\n")
        ("JSON.list" "JSON.list(Result.unwrap!(JSON.parse(\"[null,false]\")))" "ok([<Json>, <Json>])\n")
        ("List.size" "List.size([1, 2])" "2\n")
        ("List.append" "List.append([1], 2)" "[1, 2]\n")
        ("List.set" "List.set([1, 2], 1, 3)" "[1, 3]\n")
        ("List.repeat" "List.repeat(false, 2)" "[false, false]\n")
        ("List.reverse" "List.reverse([1, 2])" "[2, 1]\n")
        ("String.length" "String.length(\"ñ😀\")" "2\n")
        ("String.upcase" "String.upcase(\"a\")" "\"A\"\n")
        ("String.downcase" "String.downcase(\"A\")" "\"a\"\n")
        ("String.trim" "String.trim(\" a \")" "\"a\"\n")
        ("String.split" "String.split(\"ñ😀\", \"\")" "[\"ñ\", \"😀\"]\n")
        ("String.join" "String.join([\"a\", \"b\"], \",\")" "\"a,b\"\n")
        ("String.contains?" "String.contains?(\"abc\", \"b\")" "true\n")
        ("String.starts_with?" "String.starts_with?(\"abc\", \"a\")" "true\n")
        ("String.ends_with?" "String.ends_with?(\"abc\", \"c\")" "true\n")
        ("String.replace" "String.replace(\"aXb\", \"X\", \"-\")" "\"a-b\"\n")
        ("String.slice" "String.slice(\"ñ😀x\", 1, 2)" "\"😀x\"\n")
        ("String.from_int" "String.from_int(7)" "\"7\"\n")
        ("String.from_float" "String.from_float(1.5)" "\"1.5\"\n")
        ("String.from_bytes" "String.from_bytes([195, 177])" "ok(\"ñ\")\n")
        ("String.to_int" "String.to_int(\"7\")" "ok(7)\n")
        ("String.to_float" "String.to_float(\"1.5\")" "ok(1.5)\n")
        ("String.to_int!" "String.to_int!(\"7\")" "7\n")
        ("String.to_float!" "String.to_float!(\"1.5\")" "1.5\n")
        ("ok" "ok(7)" "ok(7)\n")
        ("error" "r" "error(\"bad\")\n")
        ("Result.ok?" "Result.ok?(ok(7))" "true\n")
        ("Result.unwrap!" "Result.unwrap!(ok(7))" "7\n")
        ("Result.unwrap_or" "Result.unwrap_or(r, 7)" "7\n")
        ("Result.message" "Result.message(r)" "\"bad\"\n")))
    (for ([name (in-list (sort (hash-keys builtins) string<?))])
      (define sample (assoc name samples))
      (unless sample (error 'catalog-test "missing behavioral example for ~a" name))
      (define-values (out err result)
        (run-io (main-with (format "  r: Result[Int] = error(\"bad\")\n  IO.inspect(~a)" (cadr sample)))
                "line\n" '("arg")))
      (check-equal? out (caddr sample) name)
      (check-equal? err (if (equal? name "IO.warn") "x\n" "") name)
      (if (equal? name "System.exit")
          (check-equal? (exit-code-code result) 0)
          (check-equal? result 'nil name))))

  (test-case "collection operations preserve originals, order, and present false/nil values"
    (check-equal?
     (output-of
      (string-append
       "def fallback() -> Int\n  puts(\"default\")\n  return 9\nend\n"
       (main-with
        (string-append
         "  xs = [1, 2]\n  ys = List.set(xs, 0, 3)\n"
         "  IO.inspect(xs)\n  IO.inspect(List.append(ys, 4))\n"
         "  nested = List.repeat(xs, 2)\n  IO.inspect(List.set(nested, 1, ys))\n"
         "  IO.inspect(nested)\n  IO.inspect(List.reverse(xs))\n"
         "  empty: List[Int] = List.repeat(7, 0)\n  IO.inspect(empty)\n"
         "  IO.inspect(List.size(List.repeat(nil, 1048576)))\n"
         "  m = {\"a\": 1, \"b\": 2, \"c\": 3}\n"
         "  deleted = Map.delete(m, \"b\")\n  absent = Map.delete(deleted, \"missing\")\n"
         "  replaced = Map.put(absent, \"a\", 7)\n  added = Map.put(replaced, \"b\", 8)\n"
         "  IO.inspect(Map.values(m))\n  IO.inspect(Map.keys(added))\n"
         "  IO.inspect(Map.values(added))\n  IO.inspect(Map.size(deleted))\n"
         "  IO.inspect(Map.get(m, \"a\", fallback()))\n  IO.inspect(Map.get(m, \"missing\", 9))\n"
         "  IO.inspect(Result.ok?(Map.get(m, \"missing\")))\n"
         "  IO.inspect(Map.get({\"f\": false}, \"f\"))\n"
         "  IO.inspect(Map.get({\"n\": nil}, \"n\"))\n"
         "  IO.inspect(Map.get({\"f\": false}, \"f\", true))\n"
         "  IO.inspect(Map.get({\"n\": nil}, \"n\", nil))\n"
         "  IO.inspect(Map.delete(Map.delete(m, \"a\"), \"b\"))"))))
     (string-append
      "[1, 2]\n[3, 2, 4]\n[[1, 2], [3, 2]]\n[[1, 2], [1, 2]]\n[2, 1]\n[]\n1048576\n"
      "[1, 2, 3]\n[\"a\", \"c\", \"b\"]\n[7, 3, 8]\n2\ndefault\n1\n9\nfalse\n"
      "ok(false)\nok(nil)\nfalse\nnil\n{\"c\": 3}\n")))

  (test-case "list updates and allocations reject invalid arguments at their spans"
    (for ([entry '(("List.set([1], -1, 2)" RUNTIME-INDEX-OUT-OF-RANGE)
                   ("List.set([1], 1, 2)" RUNTIME-INDEX-OUT-OF-RANGE)
                   ("List.set([], 0, 2)" RUNTIME-INDEX-OUT-OF-RANGE)
                   ("List.repeat(1, -1)" RUNTIME-INVALID-COUNT)
                   ("List.repeat(1, 1048577)" RUNTIME-INVALID-COUNT))])
      (define problem (diagnostic-of (main-with (string-append "  x = " (car entry)))))
      (check-equal? (diagnostic-code problem) (cadr entry))
      (check-equal? (source-position-line (source-span-start (diagnostic-span problem))) 2)
      (define prefix (car (string-split (car entry) ", ")))
      (check-equal? (source-position-column (source-span-start (diagnostic-span problem)))
                    (+ 9 (string-length prefix)))))

  (test-case "JSON parsing requires one valid finite value and preserves null and false"
    (for ([text '("" " \r\n" "true false" "{}x" "nullx" "01" "+1" "1."
                  "[1,]" "{\"a\":}" "\"bad\nline\"" "\"\\uD800\""
                  "0.0001e+" "1e400" "[1e400]" "null ")])
      (check-equal? (output-of (main-with (format "  IO.inspect(Result.ok?(JSON.parse(~s)))" text)))
                    "false\n" text))
    (check-equal?
     (output-of
      (main-with
       (string-append
        "  j = Result.unwrap!(JSON.parse(\" \\t{\\\"flag\\\": true, \\\"none\\\": null, \\\"flag\\\": false}\\r\\n\"))\n"
        "  flag = Result.unwrap!(JSON.get(j, \"flag\"))\n"
        "  IO.inspect(JSON.bool(flag))\n"
        "  nothing = Result.unwrap!(JSON.get(j, \"none\"))\n"
        "  puts(JSON.encode(nothing))\n"
        "  IO.inspect(Result.ok?(JSON.get(j, \"missing\")))\n"
        "  IO.inspect(Result.ok?(JSON.bool(nothing)))\n"
        "  IO.inspect(nothing)\n"
        "  text = Result.unwrap!(JSON.parse(\"\\\"\\\\u00f1\\\\uD83D\\\\uDE00\\\\n\\\"\"))\n"
        "  IO.inspect(JSON.string(text))")))
     "ok(false)\nnull\nfalse\nfalse\n<Json>\nok(\"ñ😀\\n\")\n"))

  (test-case "JSON access and extraction reject wrong kinds and array bounds"
    (for ([expression '("JSON.get(j, \"k\")" "JSON.at(j, 0)" "JSON.string(j)"
                        "JSON.int(j)" "JSON.float(j)" "JSON.bool(j)" "JSON.list(j)")])
      (check-equal?
       (output-of (main-with (format "  j = Result.unwrap!(JSON.parse(\"null\"))\n  IO.inspect(Result.ok?(~a))" expression)))
       "false\n" expression))
    (check-equal?
     (output-of
      (main-with
       (string-append
        "  j = Result.unwrap!(JSON.parse(\"[false, null, {\\\"n\\\": 3}]\"))\n"
        "  IO.inspect(JSON.bool(Result.unwrap!(JSON.at(j, 0))))\n"
        "  puts(JSON.encode(Result.unwrap!(JSON.at(j, 1))))\n"
        "  IO.inspect(JSON.int(Result.unwrap!(JSON.get(Result.unwrap!(JSON.at(j, 2)), \"n\"))))\n"
        "  for i in [-1, 3]\n    IO.inspect(Result.ok?(JSON.at(j, i)))\n  end\n"
        "  empty = Result.unwrap!(JSON.parse(\"[]\"))\n"
        "  IO.inspect(JSON.list(empty))\n  IO.inspect(Result.ok?(JSON.at(empty, 0)))")))
     "ok(false)\nnull\nok(3)\nfalse\nfalse\nok([])\nfalse\n"))

  (test-case "JSON numbers respect integer bounds and finite Float conversion"
    (for ([entry '(("-9223372036854775808" "ok(-9223372036854775808)\n")
                   ("9223372036854775807" "ok(9223372036854775807)\n"))])
      (check-equal?
       (output-of (main-with (format "  IO.inspect(JSON.int(Result.unwrap!(JSON.parse(~s))))" (car entry))))
       (cadr entry)))
    (for ([text '("9223372036854775808" "-9223372036854775809" "1.0" "1e0" "true" "\"1\"")])
      (check-equal?
       (output-of (main-with (format "  IO.inspect(Result.ok?(JSON.int(Result.unwrap!(JSON.parse(~s)))))" text)))
       "false\n"))
    (check-equal?
     (output-of
      (main-with
       (string-append
        "  IO.inspect(JSON.float(Result.unwrap!(JSON.parse(\"1.25\"))))\n"
        "  IO.inspect(JSON.float(Result.unwrap!(JSON.parse(\"2e1\"))))\n"
        (format "  big = Result.unwrap!(JSON.parse(~s))\n" (make-string 400 #\9))
        "  IO.inspect(Result.ok?(JSON.float(big)))")))
     "ok(1.25)\nok(20.0)\nfalse\n"))

  (test-case "JSON encoding preserves declared fields and map order recursively"
    (check-equal?
     (output-of
      (string-append
       "struct Inner\n  label: String\nend\n"
       "struct Payload\n  z: Inner\n  a: Map[String, List[Bool]]\n  raw: Json\n  none: Nil\nend\n"
       "struct Node\n  children: List[Node]\n  value: Int\nend\n"
       (main-with
        (string-append
         "  p = Payload(none: nil, raw: Result.unwrap!(JSON.parse(\"[null,false,1.25]\")),\n"
         "    a: {\"b\": [false], \"a\": [], \"b\": [true, false]}, z: Inner(label: \"ñ😀\\\"\\n\"))\n"
         "  puts(JSON.encode(p))\n"
         "  roundtrip = Result.unwrap!(JSON.parse(JSON.encode(p)))\n"
         "  inner = Result.unwrap!(JSON.get(roundtrip, \"z\"))\n"
         "  IO.inspect(JSON.string(Result.unwrap!(JSON.get(inner, \"label\"))))\n"
         "  puts(JSON.encode(Node(value: 2, children: [Node(value: 1, children: [])])))\n"
         "  empty: Map[String, Json] = {}\n  puts(JSON.encode(empty))\n"
         "  puts(JSON.encode([-9223372036854775808, 9223372036854775807]))"))))
     (string-append
      "{\"z\":{\"label\":\"ñ😀\\\"\\n\"},\"a\":{\"b\":[true,false],\"a\":[]},\"raw\":[null,false,1.25],\"none\":null}\n"
      "ok(\"ñ😀\\\"\\n\")\n"
      "{\"children\":[{\"children\":[],\"value\":1}],\"value\":2}\n{}\n"
      "[-9223372036854775808,9223372036854775807]\n"))
    (define bad (diagnostic-of (main-with "  x = JSON.encode({\"bad\": String.to_float!(\"9999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999\")})")))
    (check-equal? (diagnostic-code bad) 'RUNTIME-JSON-ENCODE)
    (check-equal? (position-of bad) '(2 7)))

  (test-case "JSON parse, encode, extraction and try compose in checked programs"
    (check-equal?
     (output-of
      (string-append
       "def sum(text: String) -> Result[Int]\n"
       "  root = try JSON.parse(text)\n  counts = try JSON.get(root, \"counts\")\n"
       "  items = try JSON.list(counts)\n  total = 0\n"
       "  for item in items\n    total = total + try JSON.int(item)\n  end\n"
       "  return ok(total)\nend\n"
       (main-with
        (string-append
         "  IO.inspect(sum(JSON.encode({\"counts\": [1, 2, 3]})))\n"
         "  IO.inspect(Result.ok?(sum(\"{}\")))\n"
         "  IO.inspect(Result.ok?(sum(\"bad\")))\n"
         "  IO.inspect(Result.ok?(sum(\"{\\\"counts\\\": [1, false]}\")))\n"
         "  puts(\"continued\")"))))
     "ok(6)\nfalse\nfalse\nfalse\ncontinued\n"))

  (test-case "Result values, false/nil successes, and recoverable conversions"
    (check-equal?
     (output-of
      (main-with
       (string-append
        "  IO.inspect(ok(false))\n  IO.inspect(ok(nil))\n"
        "  r: Result[Int] = error(\"bad\")\n"
        "  IO.inspect(r)\n  IO.inspect(Result.ok?(r))\n"
        "  IO.inspect(Result.unwrap!(ok(false)))\n"
        "  IO.inspect(Result.unwrap!(ok(nil)))\n"
        "  IO.inspect(Result.message(ok(1)))\n  puts(Result.message(r))\n"
        "  IO.inspect(Result.unwrap_or(r, 7))\n"
        "  IO.inspect(String.to_int(\"-9223372036854775808\"))\n"
        "  IO.inspect(String.to_int(\"9223372036854775807\"))\n"
        "  IO.inspect(Result.ok?(String.to_int(\"9223372036854775808\")))\n"
        "  IO.inspect(Result.ok?(String.to_int(\"-9223372036854775809\")))\n"
        "  IO.inspect(Result.ok?(String.to_int(\"1.5\")))\n"
        "  IO.inspect(Result.ok?(String.to_int(\"#x10\")))\n"
        "  IO.inspect(String.to_float(\"+1.25\"))\n"
        "  IO.inspect(Result.ok?(String.to_float(\"1/2\")))\n"
        "  IO.inspect(Result.ok?(String.to_float(\"1+2i\")))\n"
        "  puts(\"continued\")")))
     (string-append "ok(false)\nok(nil)\nerror(\"bad\")\nfalse\nfalse\nnil\n\"\"\nbad\n7\n"
                    "ok(-9223372036854775808)\nok(9223372036854775807)\n"
                    "false\nfalse\nfalse\nfalse\nok(1.25)\nfalse\nfalse\ncontinued\n"))
    (define problem (diagnostic-of (main-with "  r: Result[Int] = error(\"bad\")\n  x = Result.unwrap!(r)")))
    (check-equal? (diagnostic-code problem) 'RUNTIME-UNWRAP-ERROR)
    (check-equal? (position-of problem) '(3 7)))

  (test-case "recoverable IO.gets distinguishes blank lines and EOF"
    (define-values (out err result)
      (run-io (main-with "  for n in [1, 2, 3, 4, 5, 6]\n    r = IO.gets()\n    IO.inspect(Result.ok?(r))\n    IO.inspect(Result.unwrap_or(r, \"EOF\"))\n  end")
              "\none\rtwo\r\nthree\nfour"))
    (check-equal? result 'nil)
    (check-equal? err "")
    (check-equal? out "true\n\"\"\ntrue\n\"one\"\ntrue\n\"two\"\ntrue\n\"three\"\ntrue\n\"four\"\nfalse\n\"EOF\"\n"))

  (test-case "try evaluates once and propagates from the current function only"
    (check-equal?
     (output-of
      (string-append
       "def operand() -> Result[Int]\n  puts(\"operand\")\n  return error(\"bad\")\nend\n"
       "def later() -> Int\n  puts(\"later\")\n  return 9\nend\n"
       "def pair(a: Int, b: Int) -> Int\n  return a + b\nend\n"
       "def propagate() -> Result[String]\n"
       "  for n in [1]\n    while true\n"
       "      value = pair(try operand(), later())\n"
       "      return ok(String.from_int(value))\n    end\n  end\n"
       "  return ok(\"empty\")\nend\n"
       "def success() -> Result[String]\n  n = try ok(7)\n  return ok(String.from_int(n))\nend\n"
       "def main() -> Nil\n  local = \"caller\"\n"
       "  r = propagate()\n  puts(Result.message(r))\n  puts(local)\n"
       "  puts(Result.unwrap!(success()))\nend\n"))
     "operand\nbad\ncaller\n7\n"))

  (test-case "unwrap_or evaluates its default eagerly after its Result"
    (check-equal?
     (output-of
      (string-append
       "def first() -> Result[Int]\n  puts(\"first\")\n  return ok(1)\nend\n"
       "def second() -> Int\n  puts(\"second\")\n  return 2\nend\n"
       (main-with "  IO.inspect(Result.unwrap_or(first(), second()))")))
     "first\nsecond\n1\n"))

  (test-case "step budgets bound empty infinite loops and reset each run"
    (define looping (main-with "  while true\n  end"))
    (for ([iteration (in-range 2)])
      (define-values (out err result) (run-io looping #:max-steps 10))
      (check-equal? out "")
      (check-equal? err "")
      (check-equal? (diagnostic-code result) 'RUNTIME-STEP-LIMIT)
      (check-equal? (position-of result) '(2 9)))
    (define-values (out err result) (run-io (main-with "  puts(\"done\")") #:max-steps 3))
    (check-equal? result 'nil)
    (check-equal? out "done\n"))

  (test-case "runtime errors are located diagnostics"
    (define overflow (diagnostic-of (main-with "  x = 9223372036854775807 + 1")))
    (check-equal? (diagnostic-code overflow) 'RUNTIME-INTEGER-OVERFLOW)
    (define negative (diagnostic-of (main-with "  x = 0 - 9223372036854775807 - 1\n  y = -x")))
    (check-equal? (diagnostic-code negative) 'RUNTIME-INTEGER-OVERFLOW)
    (define divide (diagnostic-of (main-with "  x = 1 / 0")))
    (check-equal? (diagnostic-code divide) 'RUNTIME-DIVISION-BY-ZERO)
    (check-equal? (position-of divide) '(2 9))
    (check-equal? (diagnostic-code (diagnostic-of (main-with "  x = 1.0 / 0.0")))
                  'RUNTIME-DIVISION-BY-ZERO)
    (check-equal? (diagnostic-code (diagnostic-of (main-with "  x = 1 % 0")))
                  'RUNTIME-DIVISION-BY-ZERO)
    (define past-end (diagnostic-of (main-with "  xs = [1, 2]\n  y = xs[2]")))
    (check-equal? (diagnostic-code past-end) 'RUNTIME-INDEX-OUT-OF-RANGE)
    (check-equal? (position-of past-end) '(3 10))
    (check-equal? (diagnostic-code (diagnostic-of (main-with "  xs = [1, 2]\n  y = xs[0 - 1]")))
                  'RUNTIME-INDEX-OUT-OF-RANGE)
    (check-equal? (diagnostic-code
                   (diagnostic-of (string-append
                                   "def loop(n: Int) -> Int\n  return loop(n + 1)\nend\n"
                                   "def main() -> Nil\n  x = loop(0)\nend\n")))
                  'RUNTIME-STACK-OVERFLOW)))
