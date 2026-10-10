#lang racket

(require (except-in rackunit check)
         "../src/ast.rkt"
         "../src/checker.rkt"
         "../src/diagnostic.rkt"
         "../src/lexer.rkt"
         "../src/parser.rkt"
         "../src/source.rkt")

(define (check-text text)
  (define parsed (parse (lex (source "test.agc" text))))
  (if (diagnostic? parsed)
      (error 'checker-test "parse failed for ~s: ~a" text (format-diagnostic parsed))
      (check parsed)))

(define (check-ok text)
  (define result (check-text text))
  (when (diagnostic? result)
    (error 'checker-test "expected a checked program for ~s, got: ~a"
           text (format-diagnostic result))))

(define (check-code text)
  (define result (check-text text))
  (if (diagnostic? result)
      (diagnostic-code result)
      (error 'checker-test "expected a diagnostic for ~s, got a program" text)))

(define (main-with body)
  (format "def main() -> Void\n~a\nend\n" body))

(module+ test
  (test-case "JSON builders and schemas enforce their input contracts"
    (check-ok (main-with "  object = JSON.object({})\n  array = JSON.array([])"))
    (for ([body '("  x = JSON.object({\"a\": 1})" "  x = JSON.array([false])"
                  "  x = JSON.null?(nil)" "  x = JSON.schema(1)")])
      (check-equal? (check-code (main-with body)) 'CHECK-TYPE-MISMATCH))
    (check-equal? (check-code (main-with "  x = JSON.from(ok(1))")) 'CHECK-NOT-ENCODABLE)
    (check-equal? (check-code (string-append "struct Bad\n  value: Json\nend\n"
                                           (main-with "  x = JSON.schema(Bad)"))) 'CHECK-NOT-DECODABLE))

  (test-case "JSON decoding accepts only decodable named structs"
    (check-ok (string-append "struct Node\n  children: List[Node]\nend\n"
                            (main-with "  r = JSON.decode(\"{}\", Node)")))
    (for ([type '("Nil" "Json" "Result[Int]" "Map[Int, String]" "Fn[Int, Int]")])
      (check-equal?
       (check-code (string-append (format "struct Bad\n  value: ~a\nend\n" type)
                                 (main-with "  r = JSON.decode(\"{}\", Bad)")))
       'CHECK-NOT-DECODABLE))
    (check-equal? (check-code (main-with "  r = JSON.decode(\"{}\", Int)")) 'CHECK-NOT-DECODABLE)
    (check-equal? (check-code (main-with "  r = JSON.decode(\"{}\", 1)")) 'CHECK-TYPE-MISMATCH)
    (check-equal? (check-code (main-with "  r = Int")) 'CHECK-TYPE-MISMATCH))

  (test-case "list callbacks enforce exact signatures and infer empty inputs"
    (define callbacks
      (string-append
       "def text(n: Int) -> String\n  return String.from_int(n)\nend\n"
       "def keep(n: Int) -> Bool\n  return n > 0\nend\n"
       "def join(acc: String, n: Int) -> String\n  return acc + String.from_int(n)\nend\n"
       "def collect(acc: List[Int], n: Int) -> List[Int]\n  return List.append(acc, n)\nend\n"
       "def ignore(n: Int) -> Void\nend\n"
       "def bad(acc: String, n: Int) -> Int\n  return n\nend\n"))
    (check-ok (string-append callbacks
               (main-with (string-append
                "  a = List.map([], &text)\n"
                "  b = List.filter([], &keep)\n"
                "  c = List.reduce([], \"\", &join)\n"
                "  d = List.reduce([1], \"\", &join)\n"
                "  e = List.reduce([1], [], &collect)"))))
    (for ([body '("  x = List.map([true], &text)"
                  "  x = List.map([1], &join)"
                  "  x = List.map([1], 1)"
                  "  x: List[Int] = List.map([1], &text)"
                  "  x = List.filter([1], &text)"
                  "  x = List.reduce([1], 0, &join)"
                  "  x = List.reduce([true], \"\", &join)"
                  "  x = List.reduce([1], \"\", &bad)"
                  "  x = List.reduce([1], \"\", &text)")])
      (check-equal? (check-code (string-append callbacks (main-with body)))
                    'CHECK-TYPE-MISMATCH))
    (check-ok (string-append callbacks
               (main-with "  a: List[Float] = List.sort([])\n  b = List.sort_by([], &text)")))
    (for ([body '("  x = List.sort([true])" "  x = List.sort([[1]])"
                  "  x = List.sort_by([1], &keep)" "  x = List.sort_by([\"a\"], &text)"
                  "  x = List.sort_by([1], &join)" "  x: List[String] = List.sort([1])")])
      (check-equal? (check-code (string-append callbacks (main-with body)))
                    'CHECK-TYPE-MISMATCH))
    (check-equal? (check-code (string-append callbacks
                                 (main-with "  x = List.map([1], &ignore)")))
                  'CHECK-VOID-VALUE)
    (for ([body '("  x = List.map([1])" "  x = List.filter()"
                  "  x = List.reduce([1], 0)")])
      (check-equal? (check-code (main-with body)) 'CHECK-ARITY)))
  (test-case "Void completion cannot enter data positions and Nil requires explicit returns"
    (define prefix "def effect() -> Void\nend\n")
    (for ([body '("  value = effect()" "  IO.inspect(effect())" "  value = ok(effect())"
                  "  value = [effect()]" "  value = effect() == effect()"
                  "  value = Result.unwrap!(ok())")])
      (check-equal? (check-code (string-append prefix (main-with body))) 'CHECK-VOID-VALUE))
    (for ([text '("struct Item\n  value: Void\nend\n"
                  "def effect(value: Void) -> Void\nend\n"
                  "def effect(value: List[Void]) -> Void\nend\n"
                  "def effect(value: Map[String, Void]) -> Void\nend\n"
                  "def effect(value: Fn[Void, Int]) -> Void\nend\n")])
      (check-equal? (check-code (string-append text (main-with ""))) 'CHECK-VOID-TYPE))
    (check-equal? (check-code "def main() -> Nil\n  return nil\nend\n") 'CHECK-MAIN)
    (check-equal? (check-code (string-append "def data() -> Nil\nend\n" (main-with ""))) 'CHECK-MISSING-RETURN)
    (check-equal? (check-code (string-append "def data() -> Nil\n  return\nend\n" (main-with ""))) 'CHECK-TYPE-MISMATCH)
    (check-equal? (check-code (main-with "  return nil")) 'CHECK-TYPE-MISMATCH)
    (check-equal? (check-code (main-with "  value: Result[Nil] = ok()")) 'CHECK-TYPE-MISMATCH)
    (check-ok (string-append prefix "def forward() -> Void\n  return effect()\nend\n"
                            "def data() -> Nil\n  return nil\nend\n"
                            (main-with "  result: Result[Void] = ok()\n  values: List[Result[Void]] = [result]\n  callback: Fn[Void] = &forward\n  callback.call()\n  Result.unwrap!(result)\n  value: Nil = data()"))))
  (test-case "filesystem module and handle type names are reserved"
    (for ([name '("File" "Dir" "Path" "FileHandle" "FileInfo")])
      (check-equal? (check-code (format "struct ~a\nend\ndef main() -> Void\nend\n" name))
                    'CHECK-REDEFINED-NAME)))

  (test-case "network handles are opaque and HTTP records and callbacks are checked"
    (check-ok (string-append
               "def handler(request: Request, writer: HttpWriter) -> Void\n  HTTP.respond(writer, 200, [], request.path, 1000)\nend\n"
               (main-with "  options: HttpServerOptions = HTTP.server_options()\n  server: Result[HttpServer] = HTTP.listen(\"127.0.0.1\", 0, &handler, options)")))
    (for ([entry '(("  socket = Socket()" CHECK-UNKNOWN-TYPE)
                   ("  response = Result.unwrap!(HTTP.get(Result.unwrap!(HTTP.client()), \"http://localhost\"))\n  text: String = response.body" CHECK-TYPE-MISMATCH)
                   ("  client = Result.unwrap!(HTTP.client())\n  JSON.encode(client)" CHECK-NOT-ENCODABLE)
                   ("  header = Header(name: \"x\", value: 1)" CHECK-TYPE-MISMATCH))])
      (check-equal? (check-code (main-with (car entry))) (cadr entry))))
  (test-case "function values check references, parameters, returns and BDD handlers"
    (define prefix "def double(n: Int) -> Int\n  return n * 2\nend\n")
    (check-ok (string-append prefix (main-with "  f: Fn[Int, Int] = &double\n  value: Int = f.call(21)")))
    (for ([entry '(("  f: Fn[String, Int] = &double" CHECK-TYPE-MISMATCH)
                   ("  f: Fn[Int, Void] = &double" CHECK-TYPE-MISMATCH)
                   ("  f = &missing" CHECK-UNKNOWN-NAME)
                   ("  value = (&double).call()" CHECK-ARITY)
                   ("  value = (&double).call(\"x\")" CHECK-TYPE-MISMATCH)
                   ("  value = 1.call()" CHECK-TYPE-MISMATCH)
                   ("  BDD.step(\"double\", &double)" CHECK-TYPE-MISMATCH)
                   ("  text = JSON.encode(&double)" CHECK-NOT-ENCODABLE))])
      (check-equal? (check-code (string-append prefix (main-with (car entry)))) (cadr entry)))
    (check-ok "def handler(args: List[String]) -> Void\nend\ndef main() -> Void\n  BDD.step(\"hello\", &handler)\nend\n"))
  (test-case "the section 8 programs pass"
    (check-ok "def main() -> Void\n  puts(\"hello\")\nend\n")
    (check-ok (string-append
               "def classify(age: Int) -> String\n"
               "  if age >= 18\n"
               "    return \"adult\"\n"
               "  elsif age >= 13\n"
               "    return \"teen\"\n"
               "  else\n"
               "    return \"child\"\n"
               "  end\n"
               "end\n"
               "\n"
               "def main() -> Void\n"
               "  puts(classify(25))\n"
               "end\n"))
    (check-ok (string-append
               "struct Todo\n"
               "  title: String\n"
               "  done: Bool\n"
               "end\n"
               "\n"
               "def main() -> Void\n"
               "  tasks: List[Todo] = [\n"
               "    Todo(title: \"Probar\", done: false),\n"
               "    Todo(title: \"Revisar\", done: true)\n"
               "  ]\n"
               "  for task in tasks\n"
               "    if not task.done\n"
               "      puts(task.title)\n"
               "    end\n"
               "  end\n"
               "end\n")))

  (test-case "forward calls and recursion pass"
    (check-ok (string-append
               "def even(n: Int) -> Bool\n"
               "  if n == 0\n"
               "    return true\n"
               "  else\n"
               "    return odd(n - 1)\n"
               "  end\n"
               "end\n"
               "\n"
               "def odd(n: Int) -> Bool\n"
               "  return even(n)\n"
               "end\n"
               "\n"
               "def main() -> Void\n"
               "  puts(\"ok\")\n"
               "end\n")))

  (test-case "the rejected section 8 examples fail"
    (check-equal? (check-code (main-with "  age: Int = \"25\"")) 'CHECK-TYPE-MISMATCH)
    (check-equal? (check-code (main-with "  if 1\n    puts(\"hello\")\n  end"))
                  'CHECK-TYPE-MISMATCH)
    (check-equal? (check-code (main-with "  values = []")) 'CHECK-EMPTY-LIST-TYPE))

  (test-case "names and types"
    (check-equal? (check-code (main-with "  x = missing")) 'CHECK-UNKNOWN-NAME)
    (check-equal? (check-code (main-with "  x: Foo = 1")) 'CHECK-UNKNOWN-TYPE)
    (check-equal? (check-code (main-with "  x: List = []")) 'CHECK-UNKNOWN-TYPE)
    (check-equal? (check-code (string-append
                               "def f() -> Void\nend\n\n"
                               "def f() -> Void\nend\n\n"
                               "def main() -> Void\nend\n"))
                  'CHECK-REDEFINED-NAME)
    (check-equal? (check-code (string-append
                               "def puts(value: String) -> Void\nend\n\n"
                               "def main() -> Void\nend\n"))
                  'CHECK-REDEFINED-NAME)
    (check-equal? (check-code (string-append
                               "struct A\n  x: Int\nend\n\n"
                               "struct A\n  y: Int\nend\n\n"
                               "def main() -> Void\nend\n"))
                  'CHECK-REDEFINED-NAME)
    (check-equal? (check-code (string-append
                               "struct IO\n  value: Int\nend\n\n"
                               "def main() -> Void\nend\n"))
                  'CHECK-REDEFINED-NAME)
    (check-equal? (check-code (string-append
                               "struct System\n  value: Int\nend\n\n"
                               "def main() -> Void\nend\n"))
                  'CHECK-REDEFINED-NAME)
    (check-equal? (check-code (main-with "  x: List[Int, Int] = []")) 'CHECK-UNKNOWN-TYPE)
    (check-equal? (check-code (string-append
                               "def f() -> Void\nend\n\n"
                               "def main() -> Void\n  x = f\nend\n"))
                  'CHECK-UNKNOWN-NAME)
    (check-ok (string-append
               "def f() -> Void\nend\n\n"
               "def main() -> Void\n  f = 1\n  puts(\"ok\")\nend\n")))

  (test-case "calls and constructors"
    (define task
      (string-append
       "struct Todo\n  title: String\n  done: Bool\nend\n\n"))
    (check-equal? (check-code (string-append
                               "def f(a: Int) -> Int\n  return a\nend\n\n"
                               "def main() -> Void\n  x = f(1, 2)\nend\n"))
                  'CHECK-ARITY)
    (check-equal? (check-code
                   (string-append task
                                  "def main() -> Void\n"
                                  "  t = Todo(title: \"x\", done: false, extra: 1)\n"
                                  "end\n"))
                  'CHECK-UNKNOWN-FIELD)
    (check-equal? (check-code
                   (string-append task
                                  "def main() -> Void\n"
                                  "  t = Todo(title: \"x\")\n"
                                  "end\n"))
                  'CHECK-MISSING-FIELD)
    (check-equal? (check-code
                   (string-append task
                                  "def main() -> Void\n"
                                  "  t = Todo(title: \"x\", title: \"y\", done: false)\n"
                                  "end\n"))
                  'CHECK-DUPLICATE-FIELD)
    (check-equal? (check-code
                   (string-append task
                                  "def main() -> Void\n"
                                  "  t = Todo(title: 1, done: false)\n"
                                  "end\n"))
                  'CHECK-TYPE-MISMATCH))

  (test-case "statements"
    (check-equal? (check-code (main-with "  x = 0\n  x = \"s\"")) 'CHECK-TYPE-MISMATCH)
    (check-equal? (check-code (main-with "  x = 0\n  x: Int = 1")) 'CHECK-ANNOTATION-ON-EXISTING)
    (check-equal? (check-code (main-with "  x = 0\n  for x in [1, 2]\n    puts(\"hi\")\n  end"))
                  'CHECK-SHADOWED-NAME)
    (check-equal? (check-code (main-with "  x = 1\n  y = x.name")) 'CHECK-UNKNOWN-METHOD)
    (check-equal? (check-code (main-with "  x = 1\n  y = x[0]")) 'CHECK-NOT-INDEXABLE)
    (check-equal? (check-code (main-with "  for i in 1\n    puts(\"hi\")\n  end"))
                  'CHECK-NOT-A-LIST)
    (check-equal? (check-code (main-with "  x = 1 + 1.5")) 'CHECK-TYPE-MISMATCH)
    (check-equal? (check-code (main-with "  for i in [1, 2]\n    i = 3\n  end"))
                  'CHECK-IMMUTABLE-ASSIGNMENT)
    (check-ok (main-with "  x: List[Int] = []\n  puts(\"ok\")")))

  (test-case "returns and entry point"
    (check-equal? (check-code (string-append
                               "def f(n: Int) -> Int\n"
                               "  if n > 0\n"
                               "    return 1\n"
                               "  end\n"
                               "end\n\n"
                               "def main() -> Void\nend\n"))
                  'CHECK-MISSING-RETURN)
    (check-equal? (check-code "def f() -> Int\n  return 1\nend\n") 'CHECK-MAIN)
    (check-equal? (check-code (string-append
                               "def main() -> Void\nend\n\n"
                               "def main() -> Void\nend\n"))
                  'CHECK-REDEFINED-NAME)
    (check-equal? (check-code "def main(x: Int) -> Void\nend\n") 'CHECK-MAIN)
    (check-equal? (check-code "def main() -> Int\n  return 1\nend\n") 'CHECK-MAIN))

  (test-case "Int literals stay in 64 bits and Float literals are Float"
    (check-ok (main-with "  x: Int = 9223372036854775807\n  y: Int = -9223372036854775808"))
    (check-equal? (check-code (main-with "  x: Int = 9223372036854775808")) 'CHECK-INT-RANGE)
    (check-equal? (check-code (main-with "  x: Int = -9223372036854775809")) 'CHECK-INT-RANGE)
    (check-ok (main-with "  x: Float = 1.0")))

  (test-case "function suffixes allow whitespace before call and declaration parentheses"
    (check-ok (string-append
               "def ready? () -> Bool\n  return true\nend\n"
               "def main() -> Void\n  x = ready? ()\n  y = String.contains? (\"a\", \"a\")\nend\n")))

  (test-case "the String module"
    (check-ok (main-with (string-append
                          "  a: Int = String.length(\"hola\")\n"
                          "  b: String = String.upcase(String.trim(\" x \"))\n"
                          "  c: List[String] = String.split(\"a,b\", \",\")\n"
                          "  d: String = String.join(c, \"-\")\n"
                          "  e: Bool = String.contains?(\"hola\", \"ol\")\n"
                          "  f: Bool = String.starts_with?(\"hola\", \"ho\")\n"
                          "  g: Bool = String.ends_with?(\"hola\", \"la\")\n"
                          "  h: String = String.replace(\"aXb\", \"X\", \"-\")\n"
                          "  i: String = String.slice(\"hola\", 1, 2)\n"
                          "  j: String = String.from_int(3) + String.from_float(1.5)\n"
                          "  k: Int = String.to_int!(\"3\")\n"
                          "  l: Float = String.to_float!(\"1.5\")")))
    (check-equal? (check-code (main-with "  x = String.length(1)")) 'CHECK-TYPE-MISMATCH)
    (check-equal? (check-code (main-with "  x = String.length()")) 'CHECK-ARITY)
    (check-equal? (check-code (main-with "  x = String.nope(\"a\")")) 'CHECK-UNKNOWN-NAME)
    (check-equal? (check-code (main-with "  x = String.join(\"a\", \",\")")) 'CHECK-TYPE-MISMATCH))

  (test-case "the IO and System modules"
    (check-ok (main-with (string-append
                          "  IO.puts(\"a\")\n"
                          "  IO.print(\"b\")\n"
                          "  IO.warn(\"c\")\n"
                          "  x: Int = IO.inspect(1)\n"
                          "  s: Result[String] = IO.gets()\n"
                          "  line: String = IO.gets!()\n"
                          "  r: String = IO.read()\n"
                          "  bytes: Result[List[Int]] = IO.read_bytes(3)\n"
                          "  decoded: Result[String] = String.from_bytes([195, 177])\n"
                          "  IO.flush()\n"
                          "  e: Bool = IO.eof?()\n"
                          "  a: List[String] = System.args()\n"
                          "  System.exit(0)")))
    (check-equal? (check-code (main-with "  IO.puts(1)")) 'CHECK-TYPE-MISMATCH)
    (check-equal? (check-code (main-with "  x = IO.gets(1)")) 'CHECK-ARITY)
    (check-equal? (check-code (main-with "  x = IO.nope()")) 'CHECK-UNKNOWN-NAME)
    (check-equal? (check-code (main-with "  System.exit(\"x\")")) 'CHECK-TYPE-MISMATCH)
    (for ([body '("  x = IO.read_bytes(\"3\")" "  x = String.from_bytes([\"x\"])"
                  "  x: String = String.from_bytes([65])" "  x: List[Int] = IO.read_bytes(1)")])
      (check-equal? (check-code (main-with body)) 'CHECK-TYPE-MISMATCH))
    (for ([body '("  x = IO.read_bytes()" "  x = IO.read_bytes(1, 2)"
                  "  IO.flush(1)" "  x = String.from_bytes()")])
      (check-equal? (check-code (main-with body)) 'CHECK-ARITY)))

  (test-case "JSON signatures and opaque types"
    (check-ok
     (main-with
      (string-append
       "  parsed: Result[Json] = JSON.parse(\"{}\")\n"
       "  j: Json = Result.unwrap!(parsed)\n"
       "  member: Result[Json] = JSON.get(j, \"key\")\n"
       "  item: Result[Json] = JSON.at(j, 0)\n"
       "  text: Result[String] = JSON.string(j)\n"
       "  integer: Result[Int] = JSON.int(j)\n"
       "  decimal: Result[Float] = JSON.float(j)\n"
       "  flag: Result[Bool] = JSON.bool(j)\n"
       "  items: Result[List[Json]] = JSON.list(j)\n"
       "  encoded: String = JSON.encode(j)")))
    (for ([body '("  x = JSON.parse(1)"
                  "  x = JSON.get(Result.unwrap!(JSON.parse(\"{}\")), 1)"
                  "  x = JSON.at(Result.unwrap!(JSON.parse(\"[]\")), \"0\")"
                  "  x = JSON.string(\"text\")"
                  "  x = JSON.int(1)"
                  "  x = JSON.float(1.0)"
                  "  x = JSON.bool(false)"
                  "  x = JSON.list([1])"
                  "  x: Int = JSON.int(Result.unwrap!(JSON.parse(\"1\")))"
                  "  x = Result.unwrap!(JSON.parse(\"1\")) == Result.unwrap!(JSON.parse(\"1\"))")])
      (check-equal? (check-code (main-with body)) 'CHECK-TYPE-MISMATCH))
    (for ([name '("parse" "encode" "get" "at" "string" "int" "float" "bool" "list")])
      (check-equal? (check-code (main-with (format "  x = JSON.~a()" name))) 'CHECK-ARITY))
    (check-equal? (check-code (main-with "  x: Json[Int] = Result.unwrap!(JSON.parse(\"1\"))"))
                  'CHECK-UNKNOWN-TYPE)
    (check-equal? (check-code (main-with "  x = Json()")) 'CHECK-UNKNOWN-TYPE)
    (check-equal? (check-code (main-with "  j = Result.unwrap!(JSON.parse(\"{}\"))\n  x = j.key"))
                  'CHECK-UNKNOWN-METHOD)
    (check-equal? (check-code (main-with "  j = Result.unwrap!(JSON.parse(\"[]\"))\n  x = j[0]"))
                  'CHECK-NOT-INDEXABLE)
    (for ([name '("Json" "JSON")])
      (check-equal? (check-code (string-append (format "struct ~a\nend\n" name) (main-with "")))
                    'CHECK-REDEFINED-NAME)))

  (test-case "JSON encoding checks nested types, including recursive structs"
    (define node "struct Node\n  children: List[Node]\n  value: Int\nend\n")
    (check-ok (string-append node (main-with "  x = JSON.encode(Node(value: 1, children: []))")))
    (check-ok (string-append
               "struct A\n  bs: List[B]\nend\nstruct B\n  as: List[A]\nend\n"
               (main-with "  x = JSON.encode(A(bs: []))")))
    (for ([body '("  x = JSON.encode(ok(1))"
                  "  x = JSON.encode([ok(1)])"
                  "  x = JSON.encode({1: \"one\"})"
                  "  x = JSON.encode({\"bad\": {1: true}})"
                  "  m: Map[Int, String] = {}\n  x = JSON.encode(m)"
                  "  xs: List[Result[Int]] = []\n  x = JSON.encode(xs)")])
      (check-equal? (check-code (main-with body)) 'CHECK-NOT-ENCODABLE))
    (define rejected
      (check-text (string-append
                   "struct Bad\n  children: List[Bad]\n  value: Result[Int]\nend\n"
                   (main-with "  x = JSON.encode(Bad(children: [], value: ok(1)))"))))
    (check-equal? (diagnostic-code rejected) 'CHECK-NOT-ENCODABLE)
    (check-equal? (source-position-line (source-span-start (diagnostic-span rejected))) 6)
    (check-equal? (source-position-column (source-span-start (diagnostic-span rejected))) 19))

  (test-case "Result inference preserves context across the shared call path"
    (check-ok
     (string-append
      "struct Box\n  value: Result[List[Int]]\nend\n"
      "def consume(value: Result[Map[String, Int]]) -> Void\nend\n"
      "def make() -> Result[List[Int]]\n  return ok([])\nend\n"
      "def main() -> Void\n"
      "  inferred = ok(1)\n"
      "  r: Result[Int] = error(\"bad\")\n  r = ok(2)\n  r = error(\"again\")\n"
      "  nested: Result[Result[Bool]] = ok(ok(false))\n"
      "  box = Box(value: error(\"bad\"))\n"
      "  consume(ok({}))\n"
      "  xs: List[Result[Int]] = [error(\"bad\"), ok(1)]\n"
      "  map: Map[String, Result[Int]] = {\"k\": error(\"bad\")}\n"
      "  inferred_list = [ok(1), error(\"bad\")]\n"
      "  a: Int = Result.unwrap!(error(\"bad\"))\n"
      "  b = Result.unwrap_or(error(\"bad\"), 7)\n"
      "  c: List[Int] = Result.unwrap_or(ok([]), [])\nend\n")))

  (test-case "Result and builtin failures retain structured diagnostics"
    (for ([body '("  r = error(\"bad\")"
                  "  r = Result.message(error(\"bad\"))"
                  "  r = [error(\"bad\"), ok(1)]")])
      (check-equal? (check-code (main-with body)) 'CHECK-RESULT-TYPE))
    (for ([body '("  r: Result[Int, String] = ok(1)"
                  "  r: Result = ok(1)"
                  "  r: Result[Missing] = ok(1)")])
      (check-equal? (check-code (main-with body)) 'CHECK-UNKNOWN-TYPE))
    (for ([body '("  r: Result[Int] = ok(\"x\")"
                  "  r: Result[Int] = error(1)"
                  "  r = Result.ok?(1)"
                  "  r = Result.unwrap_or(ok(1), \"x\")"
                  "  r = ok(1) == ok(1)")])
      (check-equal? (check-code (main-with body)) 'CHECK-TYPE-MISMATCH))
    (for ([body '("  r = ok(1, 2)" "  r = error()" "  r = Result.ok?()"
                  "  r = Result.message()" "  r = Result.unwrap!()"
                  "  r = Result.unwrap_or(ok(1))")])
      (check-equal? (check-code (main-with body)) 'CHECK-ARITY))
    (define arity (check-text (main-with "  r = String.to_int()")))
    (check-equal? (diagnostic-callee arity) "String.to_int(s: String) -> Result[Int]")
    (define mismatch (check-text (main-with "  r: Result[Int] = ok(\"x\")")))
    (check-equal? (diagnostic-expected mismatch) "Int")
    (check-equal? (diagnostic-actual mismatch) "String")
    (check-equal? (diagnostic-signature mismatch) "main() -> Void"))

  (test-case "Result constructor names cannot be declared by users"
    (for ([name '("ok" "error")])
      (for ([text (list (main-with (format "  ~a = 1" name))
                        (main-with (format "  for ~a in [1]\n  end" name))
                        (format "def ~a() -> Void\nend\n~a" name (main-with ""))
                        (format "def f(~a: Int) -> Void\nend\n~a" name (main-with ""))
                        (format "struct Box\n  ~a: Int\nend\n~a" name (main-with "")))])
        (check-equal? (check-code text) 'CHECK-REDEFINED-NAME)))
    (check-equal? (check-code (string-append "struct Result\nend\n" (main-with "")))
                  'CHECK-REDEFINED-NAME))

  (test-case "try checks context separately from operand and return types"
    (check-ok (string-append
               "def f() -> Result[String]\n"
               "  xs: List[Int] = try ok([])\n"
               "  n = try String.to_int(\"7\")\n"
               "  return ok(String.from_int(n))\nend\n" (main-with "")))
    (check-equal? (check-code (main-with "  x = try ok(1)")) 'CHECK-TRY-CONTEXT)
    (define bad (check-text (string-append
                            "def f() -> Result[Int]\n  x = try 1\n  return ok(x)\nend\n"
                            (main-with ""))))
    (check-equal? (diagnostic-code bad) 'CHECK-TYPE-MISMATCH)
    (check-equal? (diagnostic-expected bad) "Result[T]")
    (check-equal? (diagnostic-actual bad) "Int")
    (check-equal? (check-code (string-append
                             "def f() -> Result[Int]\n  x = try ok(1)\nend\n" (main-with "")))
                  'CHECK-MISSING-RETURN))

  (test-case "check diagnostics carry spans"
    (define mismatch (check-text "def main() -> Void\n  x: Int = \"s\"\nend\n"))
    (check-true (diagnostic? mismatch))
    (check-equal? (diagnostic-code mismatch) 'CHECK-TYPE-MISMATCH)
    (check-equal? (source-position-line (source-span-start (diagnostic-span mismatch))) 2)
    (check-equal? (source-position-column (source-span-start (diagnostic-span mismatch))) 12)

    (define unknown (check-text "def main() -> Void\n  x = missing\nend\n"))
    (check-true (diagnostic? unknown))
    (check-equal? (diagnostic-code unknown) 'CHECK-UNKNOWN-NAME)
    (check-equal? (source-position-line (source-span-start (diagnostic-span unknown))) 2)
    (check-equal? (source-position-column (source-span-start (diagnostic-span unknown))) 7)

    (define operator (check-text "def main() -> Void\n  x = 1 + \"a\"\nend\n"))
    (check-true (diagnostic? operator))
    (check-equal? (diagnostic-code operator) 'CHECK-TYPE-MISMATCH)
    (check-equal? (source-position-column (source-span-start (diagnostic-span operator))) 9))

  (test-case "methods resolve by receiver type and report unknown or unused calls"
    (check-ok (string-append
               "struct Item\n  name: String\nend\n"
               (main-with (string-append
                "  s = \" a b \"\n  n: Int = s.length\n  m: Int = s.size\n"
                "  parts: List[String] = s.strip.split(\" \")\n  joined: String = parts.join(\",\")\n"
                "  i: Result[Int] = s.to_i\n  j: Int = \"4\".to_i!\n  f: Result[Float] = s.to_f\n"
                "  b: Bool = s.include?(\"a\") && s.start_with?(\" \") && s.end_with?(\" \")\n"
                "  t: String = s.to_s\n  xs = [1]\n  xs = xs.push(2)\n  k: Int = xs.length + xs.size\n"
                "  ys: List[Int] = xs.map(&identity)\n"
                "  text: String = 7.to_s + 2.5.to_s\n  g: Float = 7.to_f\n  h: Result[Int] = 2.5.to_i\n"
                "  map = {\"a\": 1}\n  has: Bool = map.has_key?(\"a\")\n  v: Int = map.get(\"b\", 0)\n"
                "  r: Result[Int] = ok(1)\n  good: Bool = r.ok?\n  item = Item(name: \"x\")\n  up: String = item.name.upcase"))
               "def identity(n: Int) -> Int\n  return n\nend\n"))
    (for ([body '("  x = true.foo" "  x = 1.length" "  x = \"a\".from_int")])
      (check-equal? (check-code (main-with body)) 'CHECK-UNKNOWN-METHOD body))
    (check-equal? (check-code (main-with "  s = \"a\"\n  x = s.lenght")) 'CHECK-UNKNOWN-METHOD)
    (check-equal? (check-code (main-with "  x = [1].join(\",\")")) 'CHECK-TYPE-MISMATCH)
    (define struct-method
      (check-text (string-append "struct Item\n  name: String\nend\n"
                                 "def total(i: Item) -> Int\n  return 1\nend\n"
                                 (main-with "  i = Item(name: \"a\")\n  x = i.total()"))))
    (check-equal? (diagnostic-code struct-method) 'CHECK-UNKNOWN-METHOD)
    (check-regexp-match #rx"total\\(" (diagnostic-help struct-method))
    (check-regexp-match #rx"length" (diagnostic-help (check-text (main-with "  s = \"a\"\n  x = s.lenght"))))
    (check-equal? (check-code (main-with "  x = \"a\".to_s(1)")) 'CHECK-ARITY)
    (check-equal? (check-code (main-with "  x = \"a\".split")) 'CHECK-ARITY)
    (for ([body '("  xs = [1]\n  xs.push(2)" "  s = \"a\"\n  s.upcase" "  String.trim(\" a \")"
                  "  s = \"a\"\n  s.to_s")])
      (check-equal? (check-code (main-with body)) 'CHECK-UNUSED-VALUE body))
    (define unused (check-text (main-with "  xs = [1]\n  xs.push(2)")))
    (check-equal? (source-position-column (source-span-start (diagnostic-span unused))) 3)
    (check-regexp-match #rx"xs =" (diagnostic-help unused))
    (check-ok (main-with "  Result.unwrap!(ok(1))\n  \"4\".to_i!\n  IO.inspect(\"a\".upcase)")))

  (test-case "compound assignment keeps the assignment and operator rules"
    (check-equal? (check-code (main-with "  x += 1")) 'CHECK-UNKNOWN-NAME)
    (check-equal? (check-code (main-with "  x = 1\n  x += \"a\"")) 'CHECK-TYPE-MISMATCH)
    (check-equal? (check-code (main-with "  for i in [1]\n    i += 1\n  end"))
                  'CHECK-IMMUTABLE-ASSIGNMENT)
    (check-equal? (check-code (main-with "  x = !1")) 'CHECK-TYPE-MISMATCH)
    (check-equal? (check-code (main-with "  x = 1 && true")) 'CHECK-TYPE-MISMATCH))

  (test-case "diagnostics carry types, operand labels, and the enclosing signature"
    (define problem
      (check-text "def total(q: Int, p: Float) -> Float\n  return q * p\nend\ndef main() -> Void\nend\n"))
    (check-equal? (diagnostic-code problem) 'CHECK-TYPE-MISMATCH)
    (check-equal? (diagnostic-expected problem) "Int")
    (check-equal? (diagnostic-actual problem) "Float")
    (check-equal? (length (diagnostic-labels problem)) 2)
    (check-true (string? (diagnostic-help problem)))
    (check-equal? (diagnostic-signature problem) "total(q: Int, p: Float) -> Float")
    (define arity
      (check-text "def f(a: Int) -> Int\n  return a\nend\ndef main() -> Void\n  x = f(1, 2)\nend\n"))
    (check-equal? (diagnostic-code arity) 'CHECK-ARITY)
    (check-equal? (diagnostic-callee arity) "f(Int) -> Int"))

  (test-case "grounded suggestions appear only when the fix is certain"
    (define (help-of text)
      (define problem (check-text text))
      (check-true (diagnostic? problem))
      (diagnostic-help problem))
    (define item "struct Item\n  name: String\n  price: Int\nend\n")
    (check-regexp-match #rx"total"
                        (help-of "def total() -> Int\n  return 1\nend\ndef main() -> Void\n  x = totl()\nend\n"))
    (check-false (help-of (main-with "  x = qqqq")))
    (check-regexp-match #rx"price"
                        (help-of (string-append item "def main() -> Void\n  i = Item(name: \"a\", price: 1)\n  x = i.prise\nend\n")))
    (check-regexp-match #rx"price: \\.\\.\\.\" with a value of type Int"
                        (help-of (string-append item "def main() -> Void\n  i = Item(name: \"a\")\nend\n")))
    (check-regexp-match #rx"String"
                        (help-of (main-with "  x: Strng = \"a\"")))
    (check-regexp-match #rx"String.from_int"
                        (help-of (main-with "  puts(1)")))
    (check-regexp-match #rx"else"
                        (help-of "def f(n: Int) -> Int\n  if n > 0\n    return 1\n  end\nend\ndef main() -> Void\nend\n"))
    (check-regexp-match #rx"return <value>"
                        (help-of "def f(n: Int) -> Int\n  x = n\nend\ndef main() -> Void\nend\n"))
    (check-regexp-match #rx"x = value"
                        (help-of (main-with "  x = 1\n  for x in [1]\n    puts(\"a\")\n  end")))
    (check-regexp-match #rx"copy the value"
                        (help-of (main-with "  for i in [1]\n    i = 2\n  end"))))

  (test-case "maps and the Map and List modules"
    (check-ok
     (main-with
      (string-append
       "  xs: List[List[Int]] = List.append([], [])\n"
       "  ys: List[List[Int]] = List.repeat([], 2)\n"
       "  zs: List[Int] = List.reverse([])\n"
       "  rs: List[Result[Int]] = List.repeat(error(\"bad\"), 0)\n"
       "  a = List.concat([], [1])\n"
       "  b: List[List[Int]] = List.concat([], [[]])\n"
       "  c: List[Int] = List.concat([], [])\n"
       "  d: List[Int] = List.take([], 0)\n"
       "  e: List[Int] = List.drop([], 2)\n"
       "  f: Result[Int] = List.at([error(\"bad\")], 0)\n"
       "  filled = List.append([], 1)\n"
       "  replaced: List[List[Int]] = List.set(ys, 0, [])\n"
       "  m: Map[String, List[Int]] = {}\n"
       "  r: Result[List[Int]] = Map.get(m, \"x\")\n"
       "  value: List[Int] = Map.get(m, \"x\", [])\n"
       "  inferred = Map.get({}, \"x\", 1)\n"
       "  missing: Result[Int] = Map.get({}, \"x\")\n"
       "  nested: Result[Int] = Map.get({}, \"x\", error(\"bad\"))\n"
       "  deleted: Map[String, Int] = Map.delete({}, \"x\")\n"
       "  values: List[List[Int]] = Map.values(m)")))
    (for ([body '("  x = List.append([1], false)"
                  "  x = List.set([1], true, 2)"
                  "  x = List.set([1], 0, \"x\")"
                  "  x = List.repeat(1, false)"
                  "  x = List.reverse(1)"
                  "  x = List.concat([1], [false])"
                  "  x = List.concat([], 1)"
                  "  x = List.take([1], true)"
                  "  x = List.drop(1, 0)"
                  "  x = List.at([1], false)"
                  "  x: String = List.at([1], 0)"
                  "  x = Map.get({\"x\": 1}, 0)"
                  "  x = Map.get({\"x\": 1}, \"x\", false)"
                  "  x: Int = Map.get({\"x\": 1}, \"x\")"
                  "  x: Result[Int] = Map.get({\"x\": 1}, \"x\", 2)"
                  "  x = Map.delete({\"x\": 1}, 0)"
                  "  x = Map.values([1])")])
      (check-equal? (check-code (main-with body)) 'CHECK-TYPE-MISMATCH))
    (for ([body '("  x = Map.get()" "  x = Map.get({\"x\": 1})"
                  "  x = Map.get({\"x\": 1}, \"x\", 2, 3)"
                  "  x = List.append([1])" "  x = List.set([1], 0)"
                  "  x = List.repeat(1)" "  x = List.reverse()"
                  "  x = List.concat([1])" "  x = List.take([1])"
                  "  x = List.drop()" "  x = List.at([1], 0, 1)"
                  "  x = Map.delete({\"x\": 1})" "  x = Map.values()")])
      (check-equal? (check-code (main-with body)) 'CHECK-ARITY))
    (check-ok (main-with (string-append
                          "  m: Map[String, Int] = {\"a\": 1}\n"
                          "  n = Map.put(m, \"b\", m[\"a\"])\n"
                          "  e: Map[Int, String] = {}\n"
                          "  ks: List[String] = Map.keys(n)\n"
                          "  total: Int = Map.size(n) + List.size(ks)\n"
                          "  found: Bool = Map.has_key?(n, \"a\")")))
    (check-equal? (check-code (main-with "  m: Map[Float, Int] = {}")) 'CHECK-MAP-KEY-TYPE)
    (check-equal? (check-code (main-with "  m: Map[String] = {}")) 'CHECK-UNKNOWN-TYPE)
    (check-equal? (check-code (main-with "  m = {1.5: 1}")) 'CHECK-MAP-KEY-TYPE)
    (check-equal? (check-code (main-with "  m = {\"a\": 1}\n  x = m[1]")) 'CHECK-TYPE-MISMATCH)
    (check-equal? (check-code (main-with "  m = {\"a\": 1}\n  x = Map.put(m, \"b\", \"c\")"))
                  'CHECK-TYPE-MISMATCH)
    (check-equal? (check-code (main-with "  m = {}")) 'CHECK-EMPTY-MAP-TYPE)
    (check-equal? (check-code (main-with "  x = Map.size()")) 'CHECK-ARITY)
    (check-equal? (check-code (main-with "  x = Map.nope(1)")) 'CHECK-UNKNOWN-NAME)
    (check-equal? (check-code (main-with "  x = Mpa.put(1)")) 'CHECK-UNKNOWN-NAME)
    (check-equal? (check-code (main-with "  m = {\"a\": 1}\n  x = m == m")) 'CHECK-TYPE-MISMATCH))

  (test-case "generic enum construction infers and checks type arguments"
    (define source
      (string-append
       "enum Option[T]\n  Some(T)\n  None\nend\n"
       "def main() -> Void\n"
       "  number: Option[Int] = Option.Some(1)\n"
       "  text: Option[String] = Option.None()\n"
       "end\n"))
    (check-ok source)
    (check-equal?
     (check-code (string-append "enum Empty[T]\n  None\nend\n"
                                (main-with "  x = Empty.None()")))
     'CHECK-ENUM-TYPE-INFERENCE)
    (check-equal?
     (check-code (string-append "enum Same[T]\n  Pair(T, T)\nend\n"
                                (main-with "  x = Same.Pair(1, \"text\")")))
     'CHECK-TYPE-MISMATCH)
    (check-equal?
     (check-code (string-append "enum Box[T]\n  Items(List[T])\nend\n"
                                (main-with "  x = Box.Items([])")))
     'CHECK-ENUM-TYPE-INFERENCE))

  (test-case "case checks enum and Result exhaustiveness and branch bindings"
    (check-ok
     (string-append
      "enum Option[T]\n  Some(T)\n  None\nend\n"
      "def extract(value: Option[Int]) -> Int\n"
      "  case value do\n"
      "    Option.Some(item) ->\n      return item\n"
      "    Option.None ->\n      return 0\n"
      "  end\nend\n"
      "def result() -> Result[Void]\n  return ok()\nend\n"
      "def main() -> Void\n"
      "  case result() do\n"
      "    Result.Ok(_) ->\n      puts(\"ok\")\n"
      "    Result.Err(message) ->\n      puts(message)\n"
      "  end\nend\n"))
    (check-equal?
     (check-code (string-append "enum Option[T]\n  Some(T)\n  None\nend\n"
                                (main-with (string-append
                                            "  case Option.Some(1) do\n"
                                            "    Option.Some(value) ->\n      puts(String.from_int(value))\n"
                                            "  end"))))
     'CHECK-NON-EXHAUSTIVE-CASE)
    (check-equal?
     (check-code (main-with (string-append
                             "  case true do\n    true ->\n      puts(\"yes\")\n"
                             "    false ->\n      puts(\"no\")\n  end")))
     'CHECK-NON-EXHAUSTIVE-CASE)
    (check-equal?
     (check-code (main-with (string-append
                             "  case true do\n    _ ->\n      puts(\"yes\")\n"
                             "    false ->\n      puts(\"no\")\n  end")))
     'CHECK-UNREACHABLE-CASE-ARM)
    (check-equal?
     (check-code (main-with "  case nil do\n    nil ->\n      puts(\"nil\")\n  end"))
     'CHECK-NON-EXHAUSTIVE-CASE)
    (check-ok (main-with "  case nil do\n    nil ->\n      puts(\"nil\")\n    _ ->\n      puts(\"other\")\n  end"))
    (check-equal?
     (check-code (main-with "  case true do\n    1 ->\n      puts(\"one\")\n    _ ->\n      puts(\"other\")\n  end"))
     'CHECK-PATTERN-TYPE)
    (check-equal?
     (check-code (string-append "enum State\n  Ready\n  Done\nend\n"
                                (main-with (string-append
                                            "  case State.Ready() do\n"
                                            "    State.Missing ->\n      puts(\"missing\")\n"
                                            "    _ ->\n      puts(\"other\")\n  end"))))
     'CHECK-UNKNOWN-VARIANT)
    (check-equal?
     (check-code (string-append "enum State\n  Ready\n  Done\nend\n"
                                (main-with (string-append
                                            "  case State.Ready() do\n"
                                            "    State.Ready ->\n      puts(\"ready\")\n"
                                            "    State.Ready ->\n      puts(\"again\")\n"
                                            "    State.Done ->\n      puts(\"done\")\n  end"))))
     'CHECK-UNREACHABLE-CASE-ARM)))
