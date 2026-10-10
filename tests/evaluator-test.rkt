#lang racket

(require (except-in rackunit check)
         (only-in json string->jsexpr)
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
  (format "def main() -> Void\n~a\nend\n\n" body))

(define (position-of problem)
  (define start (source-span-start (diagnostic-span problem)))
  (list (source-position-line start) (source-position-column start)))

(module+ test
  (test-case "Void Results and tasks complete without turning nil data into completion"
    (check-equal?
     (output-of
      (string-append "def effect(n: Int) -> Void\n  return\nend\n\n"
                     "\ndef finish() -> Result[Void]\n  return ok()\nend\n\n"
                     "\ndef propagate() -> Result[Void]\n  try finish()\n  failure: Result[Void] = error(\"bad\")\n  try failure\n  return ok()\nend\n\n"
                     (main-with "  IO.inspect(ok())\n  IO.inspect(ok(nil))\n  task: Task[Void] = Task.spawn(&effect, 0)\n  Task.await(task)\n  Task.await(task)\n  Result.unwrap!(finish())\n  IO.inspect(propagate())\n  puts(\"done\")")))
     "ok()\nok(nil)\nerror(\"bad\")\ndone\n"))
  (test-case "function values travel through parameters, returns and maps"
    (check-equal?
     (output-of
      (string-append
       "def double(n: Int) -> Int\n  return n * 2\nend\n\n"
       "\ndef select() -> Fn[Int, Int]\n  return &double\nend\n\n"
       "\ndef apply(f: Fn[Int, Int], n: Int) -> Int\n  return f.call(n)\nend\n\n"
       "\ndef main() -> Void\n  handlers: Map[String, Fn[Int, Int]] = {\"double\": select()}\n"
       "  IO.inspect(apply(handlers[\"double\"], 21))\n  IO.inspect(handlers[\"double\"])\nend\n\n"))
     "42\n<Fn>\n"))
  (test-case "the section 8 programs run"
    (check-equal? (output-of "def main() -> Void\n  puts(\"hello\")\nend\n\n") "hello\n")
    (check-equal? (output-of (string-append
                              "def classify(age: Int) -> String\n"
                              "  if age >= 18\n    return \"adult\"\n"
                              "  elsif age >= 13\n    return \"teen\"\n"
                              "  else\n    return \"child\"\n  end\nend\n\n"
                              "def main() -> Void\n"
                              "  puts(classify(25))\n  puts(classify(15))\n  puts(classify(3))\nend\n\n"))
                  "adult\nteen\nchild\n")
    (check-equal? (output-of (string-append
                              "struct Todo\n  title: String\n  done: Bool\nend\n\n"
                              "def main() -> Void\n"
                              "  tasks: List[Todo] = [\n"
                              "    Todo(title: \"a\", done: false),\n"
                              "    Todo(done: true, title: \"b\"),\n"
                              "    Todo(title: \"c\", done: false)\n  ]\n"
                              "  for task in tasks\n    if not task.done\n      puts(task.title)\n    end\n  end\nend\n\n"))
                  "a\nc\n"))

  (test-case "control flow, scopes, and recursion"
    (check-equal? (output-of (string-append
                              "def fact(n: Int) -> Int\n"
                              "  if n <= 1\n    return 1\n  end\n  return n * fact(n - 1)\nend\n\n"
                              "def find(xs: List[Int], target: Int) -> Int\n"
                              "  for x in xs\n    if x == target\n      return x\n    end\n  end\n  return 0\nend\n\n"
                              "def main() -> Void\n"
                              "  i = 0\n  total = 0\n"
                              "  while i < 4\n    total = total + i\n    i = i + 1\n  end\n"
                              "  empty: List[Int] = []\n  for e in empty\n    puts(\"never\")\n  end\n"
                              "  if total == 6\n    puts(\"six\")\n  end\n"
                              "  puts(\"ok\")\nend\n\n"
                              "\ndef unused() -> Void\n  puts(\"\")\nend\n\n"))
                  "six\nok\n")
    (check-equal? (output-of (string-append
                              "def fact(n: Int) -> Int\n"
                              "  if n <= 1\n    return 1\n  end\n  return n * fact(n - 1)\nend\n\n"
                              "def main() -> Void\n  if fact(5) == 120 and later() == 1\n    puts(\"yes\")\n  end\nend\n\n"
                              "\ndef later() -> Int\n  return 1\nend\n\n"))
                  "yes\n"))

  (test-case "operators"
    (check-equal? (output-of
                   (string-append
                    "def noisy() -> Bool\n  puts(\"ran\")\n  return true\nend\n\n"
                    "def main() -> Void\n"
                    "  if false and noisy()\n    puts(\"no\")\n  end\n"
                    "  if true or noisy()\n    puts(\"skip\")\n  end\n"
                    "  a = 0 - 7\n"
                    "  if a / 2 == 0 - 3 and a % 2 == 0 - 1\n    puts(\"trunc\")\n  end\n"
                    "  puts(\"a\" + \"b\")\nend\n\n"))
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

  (test-case "string search, characters and Float to Int conversion"
    (check-equal?
     (output-of (main-with (string-append
      "  IO.inspect(String.index_of(\"abab\", \"ba\"))\n"
      "  IO.inspect(String.index_of(\"abc\", \"\"))\n"
      "  IO.inspect(Result.ok?(String.index_of(\"abc\", \"x\")))\n"
      "  IO.inspect(String.code(String.from_code(1114111)))\n"
      "  big = Float.from_int(9223372036854775807) * 4.0\n"
      "  IO.inspect(Result.ok?(Float.to_int(big)))\n"
      "  while big < big * 10.0\n    big = big * 10.0\n  end\n"
      "  IO.inspect(Result.ok?(Float.to_int(big * 10.0)))\n"
      "  IO.inspect(Result.ok?(Float.to_int(big * 10.0 - big * 10.0)))")))
     "ok(1)\nok(0)\nfalse\n1114111\nfalse\nfalse\nfalse\n")
    (for ([case '(("  x = String.at(\"ab\", 2)" RUNTIME-INDEX-OUT-OF-RANGE (2 23))
                  ("  x = String.code(\"ab\")" RUNTIME-INVALID-CHARACTER (2 19))
                  ("  x = String.code(\"\")" RUNTIME-INVALID-CHARACTER (2 19))
                  ("  x = String.from_code(55296)" RUNTIME-INVALID-CHARACTER (2 24))
                  ("  x = String.from_code(1114112)" RUNTIME-INVALID-CHARACTER (2 24))
                  ("  x = Float.to_int!(Float.from_int(9223372036854775807))" RUNTIME-INTEGER-OVERFLOW #f)
                  ("  big = 1.0\n  while big < big * 10.0\n    big = big * 10.0\n  end\n  x = Float.to_int!(big * 10.0)"
                   RUNTIME-INVALID-NUMBER #f)
                  ("  big = 1.0\n  while big < big * 10.0\n    big = big * 10.0\n  end\n  x = Float.to_int!(big * 10.0 - big * 10.0)"
                   RUNTIME-INVALID-NUMBER #f))])
      (define found (diagnostic-of (main-with (car case))))
      (check-equal? (diagnostic-code found) (cadr case))
      (when (caddr case) (check-equal? (position-of found) (caddr case)))))

  (test-case "Random repeats with a seed, stays in bounds, and rejects empty ranges"
    (define program
      (main-with (string-append
       "  i = 0\n  good = true\n"
       "  while i < 2000\n"
       "    n = Random.int(0 - 2, 3)\n"
       "    x = Random.float()\n"
       "    good = good and n >= 0 - 2 and n <= 3 and x >= 0.0 and x < 1.0\n"
       "    i = i + 1\n  end\n"
       "  IO.inspect(good)\n"
       "  IO.inspect([Random.int(1, 1000000), Random.int(0 - 9223372036854775807 - 1, 9223372036854775807)])\n"
       "  t = Time.monotonic_ms()\n  IO.inspect(Time.monotonic_ms() >= t)")))
    (define checked (check (parse (lex (source "test.agc" program)))))
    (define (seeded seed)
      (with-output-to-string (lambda () (evaluate checked #:seed seed))))
    (check-regexp-match #rx"^true\n\\[[0-9]+, -?[0-9]+\\]\ntrue\n$" (seeded 7))
    (check-equal? (seeded 7) (seeded 7))
    (check-not-equal? (seeded 7) (seeded 8))
    (define empty (diagnostic-of (main-with "  x = Random.int(2, 1)")))
    (check-equal? (diagnostic-code empty) 'RUNTIME-INVALID-RANGE)
    (check-equal? (position-of empty) '(2 7)))

  (test-case "methods on builtin types match their module functions"
    (check-equal?
     (output-of
      (main-with (string-append
       "  words = \"  10 20 30 \".strip.split(\" \")\n"
       "  IO.inspect([words.size, words.length])\n  IO.inspect(words.join(\",\"))\n"
       "  IO.inspect(words[0].to_i)\n  IO.inspect(words[1].to_i! + 1)\n"
       "  IO.inspect(\"x\".to_i)\n  IO.inspect(\"abc\".include?(\"b\"))\n"
       "  xs = [3, 1, 2]\n  ys = xs.push(0)\n  IO.inspect(ys.sort.reverse)\n  IO.inspect(xs)\n"
       "  IO.inspect(7.to_s + \"!\")\n  IO.inspect(7.to_f / 2.0)\n"
       "  IO.inspect(2.9.to_i)\n  IO.inspect(2.9.to_s)\n"
       "  m = {\"a\": 1}\n  IO.inspect(m.get(\"b\", 5))\n  IO.inspect(m.keys)\n"
       "  r: Result[Int] = ok(3)\n  IO.inspect(r.ok?)\n  IO.inspect(r.unwrap_or(0))\n"
       "  IO.inspect(\"x\".to_s)")))
     (string-append
      "[3, 3]\n\"10,20,30\"\nok(10)\n21\nerror(\"cannot convert \\\"x\\\" to Int\")\ntrue\n"
      "[3, 2, 1, 0]\n[3, 1, 2]\n\"7!\"\n3.5\nok(2)\n\"2.9\"\n5\n[\"a\"]\ntrue\n3\n\"x\"\n"))
    (define bad-index (diagnostic-of (main-with "  s = \"ab\"\n  x = s.at(5)")))
    (check-equal? (diagnostic-code bad-index) 'RUNTIME-INDEX-OUT-OF-RANGE)
    (check-equal? (position-of bad-index) '(3 12))
    (define bad-number (diagnostic-of (main-with "  x = \"z\".to_i!")))
    (check-equal? (diagnostic-code bad-number) 'RUNTIME-INVALID-NUMBER))

  (test-case "interpolation inserts strings as is and other values in inspect form"
    (check-equal?
     (output-of
      (string-append
       "struct Item\n  name: String\n  price: Float\nend\n\n"
       (main-with (string-append
        "  n = 3\n  item = Item(name: \"tea\", price: 2.5)\n  names = [\"a\", \"b\"]\n"
        "  puts(\"n=#{n}, next=#{n + 1}\")\n"
        "  puts(\"#{item.name} #{item.price} #{item}\")\n"
        "  puts(\"#{names.join(\", \")} #{names} #{true} #{nil}\")\n"
        "  puts(\"\\#{n} # #{\"in #{n}\"}#{n}\")"))))
     (string-append "n=3, next=4\n"
                    "tea 2.5 Item(name: \"tea\", price: 2.5)\n"
                    "a, b [\"a\", \"b\"] true nil\n"
                    "#{n} # in 33\n"))
    (check-equal? (diagnostic-code (diagnostic-of (main-with "  x = \"#{1 / 0}\"")))
                  'RUNTIME-DIVISION-BY-ZERO))

  (test-case "Ruby operators and compound assignment"
    (check-equal?
     (output-of
      (string-append
       "def done!() -> Bool\n  IO.inspect(\"called\")\n  return true\nend\n\n"
       (main-with (string-append
        "  n = 0\n  b = false\n"
        "  if !b && (n < 3 || done!())\n    n += 5\n  end\n"
        "  n -= 1\n  n *= 3\n  n /= 2\n  n %= 4\n  IO.inspect(n)\n"
        "  IO.inspect(b && done!())\n"
        "  x = 1.5\n  x += 0.5\n  IO.inspect(x)\n"
        "  s = \"a\"\n  s += \"b\"\n  IO.inspect(s)"))))
     "2\nfalse\n2.0\n\"ab\"\n")
    (define overflow (diagnostic-of (main-with "  n = 9223372036854775807\n  n += 1")))
    (check-equal? (diagnostic-code overflow) 'RUNTIME-INTEGER-OVERFLOW)
    (check-equal? (position-of overflow) '(3 5)))

  (test-case "user functions may use ? and ! suffixes"
    (check-equal? (output-of
                   (string-append
                    "def ready?() -> Bool\n  return true\nend\n\n"
                    "def value!() -> String\n  return \"ok\"\nend\n\n"
                    "def main() -> Void\n"
                    "  if ready?()\n    puts(value!())\n  end\n"
                    "end\n\n"))
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
    (check-equal? result (void))
    (check-equal? output "a\nb[1, 2]\n2\n")
    (check-equal? err "w\n"))

  (test-case "IO.inspect prints structs, lists, and maps in a stable form"
    (define-values (output err result)
      (run-io (string-append
               "struct Todo\n  title: String\n  done: Bool\nend\n\n"
               "def main() -> Void\n"
               "  t = Todo(done: true, title: \"a\")\n"
               "  IO.inspect(t)\n"
               "  IO.inspect({\"k\": 1})\n"
               "  IO.inspect(\"hi\")\n"
               "  IO.inspect(nil)\n"
               "end\n\n")))
    (check-equal? result (void))
    (check-equal? output "Todo(title: \"a\", done: true)\n{\"k\": 1}\n\"hi\"\nnil\n"))

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
    (check-equal? result (void))
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
    (check-equal? result (void))
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
    (check-equal? result (void))
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

  (test-case "Ruby headers, one-line case arms and IO.gets! without parentheses run"
    (define-values (output err result)
      (run-io (string-append
               "enum Command\n  Add(Int)\n  Show\nend\n\n"
               "def main() -> Void\n  total = 0\n"
               "  while !IO.eof? do\n    line = IO.gets!.strip\n"
               "    command: Command = Command.Show()\n"
               "    if line != \"show\"\n      command = Command.Add(line.to_i!)\n    end\n"
               "    case command do\n      Command.Add(n) -> total += n\n"
               "      Command.Show -> puts(\"total #{total}\")\n    end\n  end\nend\n")
              "2\n3\nshow\n4\nshow\n"))
    (check-equal? output "total 5\ntotal 9\n"))

  (test-case "break and next leave or skip the innermost loop"
    (define-values (output err result)
      (run-io (string-append
               "def first_negative(xs: List[Int]) -> Int\n  found = 0\n  for x in xs\n"
               "    if x >= 0\n      next\n    end\n    found = x\n    break\n  end\n  return found\nend\n\n"
               "def main() -> Void\n  i = 0\n  total = 0\n  while true\n    i += 1\n"
               "    if i > 10\n      break\n    end\n    if i % 2 == 0\n      next\n    end\n"
               "    odd = i\n    total += odd\n  end\n"
               "  for x in [1, 2, 3]\n    while true\n      break\n    end\n    if x == 2\n      next\n    end\n"
               "    puts(\"#{x} #{first_negative([x, -x])}\")\n  end\n  puts(total.to_s)\nend\n")))
    (check-equal? output "1 -1\n3 -3\n25\n")
    (define-values (scoped-output scoped-err scoped-result)
      (run-io (main-with (string-append
                          "  for x in [1, 2]\n    if x == 1\n      inner = 10\n      next\n    end\n  end\n"
                          "  while true\n    if true\n      inner = 20\n      break\n    end\n  end\n"
                          "  inner = 30\n  puts(inner.to_s)"))))
    (check-equal? scoped-output "30\n"))

  (test-case "Result.Ok/Result.Err values, ok/error patterns, gets and print"
    (define-values (output err result)
      (run-io (string-append
               "def parse(line: String) -> Result[Int]\n"
               "  if line == \"\"\n    return Result.Err(\"empty\")\n  end\n"
               "  return Result.Ok(line.to_i!)\nend\n\n"
               "def main() -> Void\n"
               "  while !IO.eof?\n    line = gets!.strip\n"
               "    case parse(line)\n      ok(n) -> print(\"#{n * 2} \")\n"
               "      error(m) -> print(\"(#{m}) \")\n    end\n  end\n"
               "  r: Result[Void] = Result.Ok()\n"
               "  case r\n    ok(_) -> puts(\"done\")\n    error(_) -> puts(\"failed\")\n  end\n"
               "  case gets\n    ok(_) -> puts(\"more\")\n    error(_) -> puts(\"eof\")\n  end\nend\n")
              "2\n\n5\n"))
    (check-equal? output "4 (empty) 10 done\neof\n"))

  (test-case "IO.gets! at end of input is a located diagnostic"
    (define-values (output err result) (run-io (main-with "  x = IO.gets!()") ""))
    (check-true (diagnostic? result))
    (check-equal? (diagnostic-code result) 'RUNTIME-END-OF-INPUT)
    (check-equal? (position-of result) '(2 7)))

  (test-case "System.args and System.exit"
    (define-values (args-output err args-result)
      (run-io (main-with "  for a in System.args()\n    puts(a)\n  end") "" '("x" "y")))
    (check-equal? args-result (void))
    (check-equal? args-output "x\ny\n")
    (define-values (exit-output exit-err result) (run-io (main-with "  System.exit(3)")))
    (check-true (exit-code? result))
    (check-equal? (exit-code-code result) 3))

  (test-case "ordinary catalog entries are typed and dispatched through a real program"
    ;; Independent examples and expected output, not signatures copied from the catalog.
    (define samples
      '(("puts" "puts(\"x\")" "x\n")
        ("Task.spawn" "Task.spawn(&identity, 7)" "<Task>\n")
        ("Task.await" "Task.await(Task.spawn(&identity, 7))" "7\n")
        ("Task.sleep" "Task.sleep(0)" "")
        ("IO.puts" "IO.puts(\"x\")" "x\n")
        ("IO.print" "IO.print(\"x\")" "x")
        ("IO.warn" "IO.warn(\"x\")" "")
        ("IO.inspect" "IO.inspect(7)" "7\n7\n")
        ("IO.gets" "IO.gets()" "ok(\"line\")\n")
        ("IO.gets!" "IO.gets!()" "\"line\"\n")
        ("gets" "gets" "ok(\"line\")\n")
        ("gets!" "gets!()" "\"line\"\n")
        ("print" "print(\"x\")" "x")
        ("IO.read" "IO.read()" "\"line\\n\"\n")
        ("IO.read_bytes" "IO.read_bytes(1)" "ok([108])\n")
        ("IO.flush" "IO.flush()" "")
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
        ("JSON.object" "JSON.object({})" "<Json>\n")
        ("JSON.array" "JSON.array([])" "<Json>\n")
        ("JSON.from" "JSON.from(false)" "<Json>\n")
        ("JSON.null" "JSON.null()" "<Json>\n")
        ("JSON.null?" "JSON.null?(JSON.null())" "true\n")
        ("JSON.schema" "JSON.schema(Empty)" "<Json>\n")
        ("JSON.decode" "JSON.decode(\"{}\", Empty)" "ok(Empty())\n")
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
        ("List.sort" "List.sort([\"b\", \"B\", \"a\"])" "[\"B\", \"a\", \"b\"]\n")
        ("List.sort_by" "List.sort_by([2, 1], &identity)" "[1, 2]\n")
        ("List.map" "List.map([1, 2], &identity)" "[1, 2]\n")
        ("List.filter" "List.filter([1, 2], &positive)" "[1, 2]\n")
        ("List.reduce" "List.reduce([1, 2], 0, &add)" "3\n")
        ("List.each" "List.each([1, 2]) do |n| IO.inspect(n) end" "1\n2\n")
        ("List.any?" "List.any?([0, 2], &positive)" "true\n")
        ("List.all?" "List.all?([0, 2]) do |n| n > 0 end" "false\n")
        ("List.concat" "List.concat([1], [2])" "[1, 2]\n")
        ("List.take" "List.take([1, 2], 1)" "[1]\n")
        ("List.drop" "List.drop([1, 2], 1)" "[2]\n")
        ("List.at" "List.at([false, true], 0)" "false\n")
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
        ("String.index_of" "String.index_of(\"ñ😀.b\", \".\")" "ok(2)\n")
        ("String.at" "String.at(\"ñ😀x\", 1)" "\"😀\"\n")
        ("String.reverse" "String.reverse(\"ñ😀x\")" "\"x😀ñ\"\n")
        ("String.code" "String.code(\"😀\")" "128512\n")
        ("String.from_code" "String.from_code(241)" "\"ñ\"\n")
        ("Float.from_int" "Float.from_int(0 - 3)" "-3.0\n")
        ("Float.to_int" "Float.to_int(0.0 - 2.9)" "ok(-2)\n")
        ("Float.to_int!" "Float.to_int!(7.5)" "7\n")
        ("String.from_int" "String.from_int(7)" "\"7\"\n")
        ("String.from_float" "String.from_float(1.5)" "\"1.5\"\n")
        ("String.from_bytes" "String.from_bytes([195, 177])" "ok(\"ñ\")\n")
        ("String.to_int" "String.to_int(\"7\")" "ok(7)\n")
        ("String.to_float" "String.to_float(\"1.5\")" "ok(1.5)\n")
        ("String.to_int!" "String.to_int!(\"7\")" "7\n")
        ("String.to_float!" "String.to_float!(\"1.5\")" "1.5\n")
        ("Time.now_ms" "Time.now_ms() > 1700000000000" "true\n")
        ("Time.monotonic_ms" "Time.monotonic_ms() >= 0" "true\n")
        ("Random.int" "Random.int(3, 3)" "3\n")
        ("Random.float" "Random.float() < 1.0" "true\n")
        ("ok" "ok(7)" "ok(7)\n")
        ("error" "r" "error(\"bad\")\n")
        ("Result.ok?" "Result.ok?(ok(7))" "true\n")
        ("Result.unwrap!" "Result.unwrap!(ok(7))" "7\n")
        ("Result.unwrap_or" "Result.unwrap_or(r, 7)" "7\n")
        ("Result.message" "Result.message(r)" "\"bad\"\n")))
    (for ([name (in-list (sort (hash-keys builtins) string<?))]
          #:unless (or (string-prefix? name "BDD.")
                       (member 'filesystem (builtin-effects (hash-ref builtins name)))
                       (member 'network (builtin-effects (hash-ref builtins name)))
                       (member 'subprocess (builtin-effects (hash-ref builtins name)))))
      (define sample (assoc name samples))
      (unless sample (error 'catalog-test "missing behavioral example for ~a" name))
      (define-values (out err result)
        (run-io (string-append "struct Empty\nend\n\ndef positive(n: Int) -> Bool\n  return n > 0\nend\n\ndef add(acc: Int, n: Int) -> Int\n  return acc + n\nend\n\ndef identity(n: Int) -> Int\n  return n\nend\n\n"
                              (main-with (format "  r: Result[Int] = error(\"bad\")\n  ~a"
                                  (if (eq? (builtin-result (hash-ref builtins name)) 'Void)
                                      (cadr sample) (format "IO.inspect(~a)" (cadr sample))))))
                "line\n" '("arg")))
      (check-equal? out (caddr sample) name)
      (check-equal? err (if (equal? name "IO.warn") "x\n" "") name)
      (if (equal? name "System.exit")
          (check-equal? (exit-code-code result) 0)
          (check-equal? result (void) name))))

  (test-case "blocks capture values when created and return from themselves"
    (check-equal?
     (output-of
      (string-append
       "def make(n: Int) -> Fn[Int, Int]\n  return keep() do |x| x + n end\nend\n\n"
       "\ndef keep(f: Fn[Int, Int]) -> Fn[Int, Int]\n  return f\nend\n\n"
       (main-with (string-append
                   "  base = 10\n  add = make(base)\n  base = 0\n  IO.inspect(add.call(1))\n"
                   "  labels = [1, 5].map do |x|\n    if x > 2\n      return \"big\"\n    end\n    \"small\"\n  end\n"
                   "  IO.inspect(labels)\n  IO.inspect(add)\n"
                   "  IO.inspect([[1, 2], [3]].map do |row|\n    row.map do |v| v * 10 + base end\n  end)\n"
                   "  IO.inspect([1, 2, 3].any? do |v|\n    puts(\"saw #{v}\")\n    v == 2\n  end)"))))
     "11\n[\"small\", \"big\"]\n<Fn>\n[[10, 20], [30]]\nsaw 1\nsaw 2\ntrue\n")
    (define-values (out err limited)
      (run-io (main-with "  xs = List.repeat(1, 100)\n  ys = xs.map do |x| x + 1 end") "" '() #:max-steps 150))
    (check-equal? (diagnostic-code limited) 'RUNTIME-STEP-LIMIT)
    (define deep
      (diagnostic-of
       (string-append "def down(n: Int, f: Fn[Int, Int]) -> Int\n  return f.call(n)\nend\n\n"
                      "\ndef loop(n: Int) -> Int\n  return down(n) do |v| loop(v + 1) end\nend\n\n"
                      (main-with "  x = loop(0)"))))
    (check-equal? (diagnostic-code deep) 'RUNTIME-STACK-OVERFLOW))

  (test-case "collection operations preserve originals, order, and present false/nil values"
    (check-equal?
     (output-of
      (string-append
       "def fallback() -> Int\n  puts(\"default\")\n  return 9\nend\n\n"
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

  (test-case "collection callbacks run left to right and preserve inputs"
    (define callbacks
      (string-append
       "def show(n: Int) -> String\n  IO.inspect(n)\n  return String.from_int(n)\nend\n\n"
       "\ndef keep(n: Int) -> Bool\n  IO.inspect(n)\n  return n > 1\nend\n\n"
       "\ndef digits(acc: Int, n: Int) -> Int\n  return acc * 10 + n\nend\n\n"
       "\ndef wrap(n: Int) -> Result[Int]\n  return ok(n)\nend\n\n"
       "\ndef negate(b: Bool) -> Bool\n  return not b\nend\n\n"
       "\ndef nothing(acc: Nil, n: Int) -> Nil\n  return nil\nend\n\n"))
    (check-equal?
     (output-of
      (string-append callbacks
       (main-with (string-append
        "  xs = [1, 2, 3]\n  mapper = &show\n"
        "  IO.inspect(List.map(xs, mapper))\n"
        "  IO.inspect(List.filter(xs, &keep))\n"
        "  IO.inspect(List.reduce(xs, 0, &digits))\n"
        "  IO.inspect(List.map([], &show))\n"
        "  IO.inspect(List.filter([], &keep))\n"
        "  IO.inspect(List.reduce([], 7, &digits))\n"
        "  IO.inspect(List.map([1], &wrap))\n"
        "  IO.inspect(List.map([true, false], &negate))\n"
        "  IO.inspect(List.filter([true, false], &negate))\n"
        "  IO.inspect(List.reduce([1, 2], nil, &nothing))\n"
        "  IO.inspect(xs)"))))
     "1\n2\n3\n[\"1\", \"2\", \"3\"]\n1\n2\n3\n[2, 3]\n123\n[]\n[]\n7\n[ok(1)]\n[false, true]\n[false]\nnil\n[1, 2, 3]\n"))

  (test-case "sorting is stable, keeps the input, and puts NaN last"
    (check-equal?
     (output-of
      (string-append
       "def tens(n: Int) -> Int\n  IO.inspect(n)\n  return n / 10\nend\n\n"
       "\ndef half(x: Float) -> Float\n  return x / 2.0\nend\n\n"
       (main-with (string-append
        "  xs = [21, 12, 25, 11]\n"
        "  IO.inspect(List.sort_by(xs, &tens))\n"
        "  IO.inspect(List.sort(xs))\n"
        "  IO.inspect(xs)\n"
        "  big = 1.0\n  while big < big * 10.0\n    big = big * 10.0\n  end\n"
        "  inf = big * 10.0\n"
        "  IO.inspect(List.sort([2.0, inf - inf, -1.5, inf]))\n"
        "  IO.inspect(List.sort_by([inf - inf, 1.0, inf - inf, 0.5], &half))\n"
        "  ys: List[String] = List.sort([])\n  IO.inspect(ys)"))))
     "21\n12\n25\n11\n[12, 11, 21, 25]\n[11, 12, 21, 25]\n[21, 12, 25, 11]\n[-1.5, 2.0, +inf.0, +nan.0]\n[0.5, 1.0, +nan.0, +nan.0]\n[]\n"))

  (test-case "collection callbacks restore caller scopes and return targets"
    (define callbacks
      (string-append
       "def change(n: Int) -> Int\n  saved = n + 10\n  return saved\nend\n\n"
       "\ndef keep(n: Int) -> Bool\n  saved = n > 1\n  return saved\nend\n\n"
       "\ndef add(acc: Int, n: Int) -> Int\n  saved = acc + n\n  return saved\nend\n\n"
       "\ndef caller() -> Int\n  saved = 42\n"
       "  if true\n"
       "    local = 7\n"
       "    IO.inspect(List.map([1, 2], &change))\n"
       "    IO.inspect(List.filter([1, 2], &keep))\n"
       "    IO.inspect(List.reduce([1, 2], 0, &add))\n"
       "    IO.inspect(local)\n"
       "  end\n"
       "  return saved\nend\n\n"))
    (check-equal?
     (output-of (string-append callbacks (main-with "  IO.inspect(caller())")))
     "[11, 12]\n[2]\n3\n7\n42\n"))

  (test-case "recursive collection callbacks share the call-depth limit"
    ;; Bounded recursion would finish if each traversal reset call depth.
    (define callbacks
      (string-append
       "def descend(n: Int) -> Int\n"
       "  if n == 0\n    return 0\n  end\n"
       "  return List.map([n - 1], &descend)[0]\nend\n\n"))
    (define problem
      (diagnostic-of (string-append callbacks
                       (main-with "  IO.inspect(descend(10001))"))))
    (check-equal? (diagnostic-code problem) 'RUNTIME-STACK-OVERFLOW)
    (check-equal? (source-position-line (source-span-start (diagnostic-span problem))) 5))

  (test-case "collection callbacks propagate failure and share the step budget"
    (define callbacks "def fail(n: Int) -> Int\n  return 1 / n\nend\n\n")
    (define problem
      (diagnostic-of (string-append callbacks
                       (main-with "  xs = List.map([1, 0, 2], &fail)"))))
    (check-equal? (diagnostic-code problem) 'RUNTIME-DIVISION-BY-ZERO)
    (check-equal? (source-position-line (source-span-start (diagnostic-span problem))) 2)
    (define-values (out err result)
      (run-io (string-append callbacks
                (main-with "  xs = List.map(List.repeat(1, 100), &fail)"))
              #:max-steps 30))
    (check-equal? (diagnostic-code result) 'RUNTIME-STEP-LIMIT))

  (test-case "list helpers handle boundaries without changing their inputs"
    (check-equal?
     (output-of
      (main-with
       (string-append
        "  xs = [1, 2]\n  ys = [3]\n"
        "  IO.inspect(List.concat(xs, ys))\n"
        "  IO.inspect(List.take(xs, 0))\n"
        "  IO.inspect(List.drop(xs, 0))\n"
        "  IO.inspect(List.take(xs, 2))\n"
        "  IO.inspect(List.drop(xs, 2))\n"
        "  IO.inspect(List.take(xs, 9223372036854775807))\n"
        "  IO.inspect(List.drop(xs, 9223372036854775807))\n"
        "  empty: List[Int] = []\n"
        "  IO.inspect(List.concat(empty, xs))\n"
        "  IO.inspect(List.concat(xs, empty))\n"
        "  IO.inspect(List.take(empty, 1))\n"
        "  IO.inspect(List.drop(empty, 1))\n"
        "  IO.inspect(List.at(xs, 1))\n"
        "  IO.inspect(List.at([nil], 0))\n"
        "  IO.inspect(xs)\n  IO.inspect(ys)")))
     "[1, 2, 3]\n[]\n[1, 2]\n[1, 2]\n[]\n[1, 2]\n[]\n[1, 2]\n[1, 2]\n[]\n[]\n2\nnil\n[1, 2]\n[3]\n"))

  (test-case "list updates and allocations reject invalid arguments at their spans"
    (for ([entry '(("List.set([1], -1, 2)" RUNTIME-INDEX-OUT-OF-RANGE)
                   ("List.set([1], 1, 2)" RUNTIME-INDEX-OUT-OF-RANGE)
                   ("List.set([], 0, 2)" RUNTIME-INDEX-OUT-OF-RANGE)
                   ("List.at([1], -1)" RUNTIME-INDEX-OUT-OF-RANGE)
                   ("List.at([1], 1)" RUNTIME-INDEX-OUT-OF-RANGE)
                   ("List.at([], 0)" RUNTIME-INDEX-OUT-OF-RANGE)
                   ("List.take([1], -1)" RUNTIME-INVALID-COUNT)
                   ("List.drop([1], -1)" RUNTIME-INVALID-COUNT)
                   ("List.repeat(1, -1)" RUNTIME-INVALID-COUNT)
                   ("List.repeat(1, 1048577)" RUNTIME-INVALID-COUNT))])
      (define binding-prefix (if (equal? (car entry) "List.at([], 0)") "  x: Int = " "  x = "))
      (define problem (diagnostic-of (main-with (string-append binding-prefix (car entry)))))
      (check-equal? (diagnostic-code problem) (cadr entry))
      (check-equal? (source-position-line (source-span-start (diagnostic-span problem))) 2)
      (define prefix (car (string-split (car entry) ", ")))
      (check-equal? (source-position-column (source-span-start (diagnostic-span problem)))
                    (+ 3 (string-length binding-prefix) (string-length prefix)))))

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
       "struct Inner\n  label: String\nend\n\n"
       "\nstruct Payload\n  z: Inner\n  a: Map[String, List[Bool]]\n  raw: Json\n  none: Nil\nend\n\n"
       "\nstruct Node\n  children: List[Node]\n  value: Int\nend\n\n"
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

  (test-case "JSON builders distinguish null, false and empty containers"
    (check-equal?
     (output-of (main-with
       "  puts(JSON.encode(JSON.object({})))\n  puts(JSON.encode(JSON.array([])))\n  puts(JSON.encode(JSON.array([JSON.from(false), JSON.null(), JSON.from([1, 2])])))\n  IO.inspect(JSON.null?(JSON.from(false)))\n  IO.inspect(JSON.null?(JSON.from(nil)))\n  obj = JSON.object({\"flag\": JSON.from(false)})\n  IO.inspect(Result.unwrap!(JSON.bool(Result.unwrap!(JSON.get(obj, \"flag\")))))"))
     "{}\n[]\n[false,null,[1,2]]\nfalse\ntrue\nfalse\n")
    (check-equal?
     (output-of (main-with
       "  header = Result.unwrap!(JSON.decode(\"{\\\"name\\\":\\\"x\\\",\\\"value\\\":\\\"y\\\"}\", Header))\n  IO.inspect(header.name)\n  IO.inspect(header.value)\n  fields = Result.unwrap!(JSON.get(JSON.schema(Header), \"required\"))\n  puts(JSON.encode(fields))"))
     "\"x\"\n\"y\"\n[\"name\",\"value\"]\n")
    (define problem
      (diagnostic-of (main-with (format "  value = JSON.from([String.to_float!(~s)])" (make-string 400 #\9)))))
    (check-equal? (diagnostic-code problem) 'RUNTIME-JSON-ENCODE))

  (test-case "JSON schemas describe structs and recursive references independently"
    (define prefix
      "struct Args\n  count: Int\n  ratio: Float\n  active: Bool\n  names: List[String]\n  scores: Map[String, Int]\nend\n\n")
    (check-equal?
     (string->jsexpr (output-of (string-append prefix (main-with "  puts(JSON.encode(JSON.schema(Args)))"))))
     (hasheq 'type "object"
             'properties (hasheq 'count (hasheq 'type "integer" 'minimum (- (expt 2 63)) 'maximum (sub1 (expt 2 63)))
                                 'ratio (hasheq 'type "number")
                                 'active (hasheq 'type "boolean")
                                 'names (hasheq 'type "array" 'items (hasheq 'type "string"))
                                 'scores (hasheq 'type "object" 'additionalProperties
                                                 (hasheq 'type "integer" 'minimum (- (expt 2 63)) 'maximum (sub1 (expt 2 63)))))
             'required '("count" "ratio" "active" "names" "scores")))
    (define recursive
      (string->jsexpr (output-of (string-append "struct Node\n  children: List[Node]\nend\n\n"
                                              (main-with "  puts(JSON.encode(JSON.schema(Node)))")))))
    (define expected
      (hasheq 'type "object" 'properties (hasheq 'children (hasheq 'type "array" 'items (hasheq '$ref "#/$defs/Node")))
              'required '("children")))
    (check-equal? recursive (hash-set expected '$defs (hasheq 'Node expected))))

  (test-case "typed JSON decoding validates nested fields and preserves data"
    (define prefix
      "struct Item\n  count: Int\n  active: Bool\nend\n\nstruct Payload\n  items: List[Item]\n  weights: Map[String, Float]\nend\n\n")
    (check-equal?
     (output-of (string-append prefix
       (main-with "  p = Result.unwrap!(JSON.decode(\"{\\\"items\\\":[{\\\"count\\\":3,\\\"active\\\":false}],\\\"weights\\\":{\\\"a\\\":2},\\\"extra\\\":true}\", Payload))\n  IO.inspect(p.items[0].count)\n  IO.inspect(p.items[0].active)\n  IO.inspect(p.weights[\"a\"])\n  q = Result.unwrap!(JSON.decode(JSON.encode(p), Payload))\n  IO.inspect(q.items[0].count)")))
     "3\nfalse\n2.0\n3\n")
    (for ([text '("{\"items\":[{\"count\":1.0,\"active\":false}],\"weights\":{}}"
                  "{\"items\":[{\"count\":9223372036854775808,\"active\":false}],\"weights\":{}}"
                  "{\"items\":[{\"active\":false}],\"weights\":{}}")])
      (check-equal?
       (output-of (string-append prefix
         (main-with (format "  r = JSON.decode(~s, Payload)\n  IO.inspect(Result.ok?(r))\n  IO.inspect(String.starts_with?(Result.message(r), \"items[0].count:\"))" text))))
       "false\ntrue\n"))
    (for ([text '("invalid" "{}" "{\"items\":false,\"weights\":{}}" "{\"items\":[],\"weights\":{\"a\":\"bad\"}}")])
      (check-equal?
       (output-of (string-append prefix
         (main-with (format "  IO.inspect(Result.ok?(JSON.decode(~s, Payload)))" text))))
       "false\n")))

  (test-case "JSON parse, encode, extraction and try compose in checked programs"
    (check-equal?
     (output-of
      (string-append
       "def sum(text: String) -> Result[Int]\n"
       "  root = try JSON.parse(text)\n  counts = try JSON.get(root, \"counts\")\n"
       "  items = try JSON.list(counts)\n  total = 0\n"
       "  for item in items\n    total = total + try JSON.int(item)\n  end\n"
       "  return ok(total)\nend\n\n"
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
    (check-equal? result (void))
    (check-equal? err "")
    (check-equal? out "true\n\"\"\ntrue\n\"one\"\ntrue\n\"two\"\ntrue\n\"three\"\ntrue\n\"four\"\nfalse\n\"EOF\"\n"))

  (test-case "try evaluates once and propagates from the current function only"
    (check-equal?
     (output-of
      (string-append
       "def operand() -> Result[Int]\n  puts(\"operand\")\n  return error(\"bad\")\nend\n\n"
       "\ndef later() -> Int\n  puts(\"later\")\n  return 9\nend\n\n"
       "\ndef pair(a: Int, b: Int) -> Int\n  return a + b\nend\n\n"
       "\ndef propagate() -> Result[String]\n"
       "  for n in [1]\n    while true\n"
       "      value = pair(try operand(), later())\n"
       "      return ok(String.from_int(value))\n    end\n  end\n"
       "  return ok(\"empty\")\nend\n\n"
       "\ndef success() -> Result[String]\n  n = try ok(7)\n  return ok(String.from_int(n))\nend\n\n"
       "\ndef main() -> Void\n  local = \"caller\"\n"
       "  r = propagate()\n  puts(Result.message(r))\n  puts(local)\n"
       "  puts(Result.unwrap!(success()))\nend\n\n"))
     "operand\nbad\ncaller\n7\n"))

  (test-case "unwrap_or evaluates its default eagerly after its Result"
    (check-equal?
     (output-of
      (string-append
       "def first() -> Result[Int]\n  puts(\"first\")\n  return ok(1)\nend\n\n"
       "\ndef second() -> Int\n  puts(\"second\")\n  return 2\nend\n\n"
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
    (check-equal? result (void))
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
                                   "def loop(n: Int) -> Int\n  return loop(n + 1)\nend\n\n"
                                   "\ndef main() -> Void\n  x = loop(0)\nend\n\n")))
                  'RUNTIME-STACK-OVERFLOW))

  (test-case "enum constructors and case matching bind or discard payloads"
    (check-equal?
     (output-of
      (string-append
       "enum Option[T]\n  Some(T)\n  None\nend\n\n"
       "\ndef success() -> Result[Void]\n  return ok()\nend\n\n"
       "\ndef failure() -> Result[Int]\n  return error(\"bad\")\nend\n\n"
       "\ndef main() -> Void\n"
       "  value = Option.Some(\"payload\")\n"
       "  case value do\n"
       "    Option.Some(item) ->\n      puts(item)\n"
       "    Option.None ->\n      puts(\"none\")\n"
       "  end\n"
       "  empty: Option[Int] = Option.None()\n"
       "  case empty do\n"
       "    Option.Some(_) ->\n      puts(\"unused\")\n"
       "    Option.None ->\n      puts(\"empty\")\n"
       "  end\n"
       "  case success() do\n"
       "    Result.Ok(_) ->\n      puts(\"ok\")\n"
       "    Result.Err(message) ->\n      puts(message)\n"
       "  end\n"
       "  case failure() do\n"
       "    Result.Ok(_) ->\n      puts(\"unexpected\")\n"
       "    Result.Err(message) ->\n      puts(message)\n"
       "  end\n"
       "end\n\n"))
     "payload\nempty\nok\nbad\n")))
