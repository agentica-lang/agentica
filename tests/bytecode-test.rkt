#lang racket

(require (except-in rackunit check)
         racket/runtime-path
         "../src/builtins.rkt"
         "../src/bytecode.rkt"
         "../src/checker.rkt"
         "../src/diagnostic.rkt"
         "../src/lexer.rkt"
         "../src/lower.rkt"
         "../src/modules.rkt"
         "../src/parser.rkt"
         "../src/source.rkt")

(define-runtime-path vm-header "../vm/value.h")

(for ([name '(#"AGENTICA_VM_TRACE" #"AGENTICA_VM_TRACE_FILE" #"AGENTICA_FLUSH_TIMEOUT_MS")])
  (environment-variables-set! (current-environment-variables) name #f))

(define (lower-text text)
  (define types (make-hasheq))
  (define checked (check (parse (lex (source "test.agc" text))) #:types types))
  (when (diagnostic? checked) (error 'bytecode-test "~a" (format-diagnostic checked)))
  (lower checked types))

;; Programs with module constants go through the linker, which rewrites the reads.
(define (lower-linked-text text)
  (define linked (link-program (parse (lex (source "test.agc" text))) (string->path "test.agc")))
  (when (diagnostic? linked) (error 'bytecode-test "~a" (format-diagnostic linked)))
  (define types (make-hasheq))
  (define checked (check linked #:types types))
  (when (diagnostic? checked) (error 'bytecode-test "~a" (format-diagnostic checked)))
  (lower checked types))

(module+ test
  (test-case "every builtin runs on the VM"
    (for* ([entry (in-hash-values builtins)]
           [variant (in-list (cons entry (builtin-alternatives entry)))])
      (define key (builtin-implementation variant))
      (check-not-false (member key vm-builtins) (format "~a is not in vm-builtins" key))))

  (test-case "Task.await takes the Result entry only when R is a Result"
    (define (await-key result-type body)
      (define program
        (ir->bytecode
         (lower-text (format "def f(n: Int) -> ~a\n  return ~a\nend\n\ndef main() -> Void\n  t = Task.spawn(&f, 1)\n  IO.inspect(Task.await(t))\nend\n"
                             result-type body))))
      (filter (lambda (name) (string-prefix? name "Task.await")) (map car (bc-program-builtins program))))
    (check-equal? (await-key "Result[Int]" "ok(n)") '("Task.await_result"))
    (check-equal? (await-key "Int" "n") '("Task.await")))

  (test-case "Task.await with a timeout takes the Result entry only when R is a Result"
    (define (await-key result-type body)
      (define program
        (ir->bytecode
         (lower-text (format "def f(n: Int) -> ~a\n  return ~a\nend\n\ndef main() -> Void\n  t = Task.spawn(&f, 1)\n  IO.inspect(Task.await(t, 10))\nend\n"
                             result-type body))))
      (filter (lambda (name) (string-prefix? name "Task.await")) (map car (bc-program-builtins program))))
    (check-equal? (await-key "Result[Int]" "ok(n)") '("Task.await_result"))
    (check-equal? (await-key "Int" "n") '("Task.await")))

  (test-case "the Await enum is in the program only when it is used"
    (define (enum-names text)
      (map ir-enum-name (ir-program-enums (lower-text text))))
    (check-equal? (enum-names "def main() -> Void\n  puts(1)\nend\n") '())
    (check-equal? (enum-names "def f(n: Int) -> Int\n  return n\nend\n\ndef main() -> Void\n  _ = Task.await(Task.spawn(&f, 1), 10)\nend\n") '("Await"))
    (check-equal? (enum-names "enum Color\n  Red\nend\n\ndef f(n: Int) -> Int\n  return n\nend\n\ndef main() -> Void\n  _ = Task.await(Task.spawn(&f, 1), 10)\nend\n") '("Color" "Await")))

  (test-case "adjacent steps merge into one STEP with one span each"
    (define program (ir->bytecode (lower-text "def main() -> Void\n  puts(\"hi\")\nend\n")))
    (define main (list-ref (bc-program-functions program) (bc-program-entry program)))
    (check-equal? (vector-ref (bc-function-code main) 0)
                  (list (index-of opcodes 'step) 3 0 0)))

  (test-case "only a returned user call becomes a tail call"
    (define program
      (ir->bytecode
       (lower-text (string-append
                    "def f(n: Int) -> Int\n  if n > 0\n    return f(n - 1)\n  end\n  return 1 + f(n)\nend\n\n"
                    "def g(n: Int) -> String\n  return String.from_int(n)\nend\n\n"
                    "def main() -> Void\n  puts(f(2))\nend\n"))))
    (define (ops index)
      (for/list ([instr (in-vector (bc-function-code (list-ref (bc-program-functions program) index)))]
                 #:when (memv (first instr) (map (lambda (op) (index-of opcodes op))
                                                 '(call tail-call call-builtin return))))
        (list-ref opcodes (first instr))))
    (check-equal? (ops 0) '(tail-call call return return))
    (check-equal? (ops 1) '(call-builtin return return))
    (check-equal? (ops 2) '(call call-builtin return)))

  (test-case "a returned try is not a tail call"
    (define program
      (ir->bytecode
       (lower-text (string-append
                    "def h(n: Int) -> Result[Result[Int]]\n  return ok(ok(n))\nend\n\n"
                    "def g(n: Int) -> Result[Int]\n  return try h(n)\nend\n\n"
                    "def main() -> Void\n  puts(g(2))\nend\n"))))
    (define g (list-ref (bc-program-functions program) 1))
    (check-equal? (for/list ([instr (in-vector (bc-function-code g))]
                             #:when (memv (first instr) (map (lambda (op) (index-of opcodes op))
                                                             '(call tail-call try return))))
                    (list-ref opcodes (first instr)))
                  '(call try return return)))

  (test-case "a map literal above 255 entries adds the rest with Map.put"
    (define entries (string-join (for/list ([k (in-range 257)]) (format "~a: ~a" k k)) ", "))
    (define program
      (ir->bytecode (lower-text (format "def main() -> Void\n  puts({~a})\nend\n" entries))))
    (define main (list-ref (bc-program-functions program) (bc-program-entry program)))
    (check-equal? (for/list ([instr (in-vector (bc-function-code main))]
                             #:when (memv (first instr) (map (lambda (op) (index-of opcodes op))
                                                             '(map map-get call-builtin))))
                    (list (list-ref opcodes (first instr)) (fourth instr)))
                  '((map 255) (call-builtin 0) (call-builtin 0) (call-builtin 0)))
    (check-equal? (bc-program-builtins program) '(("Map.put" . 3) ("puts" . 1))))

  (test-case "a block becomes a function with its captures after its parameters"
    (define ir
      (lower-text (string-append
                   "def ap(f: Fn[Int, Int]) -> Int\n  return f.call(2)\nend\n\n"
                   "def main() -> Void\n  n = 1\n  m = 2\n"
                   "  xs = [1].map do |x| x + m + n end\n  puts(ap(&ap2))\n  puts(xs)\nend\n\n"
                   "def ap2(x: Int) -> Int\n  return x\nend\n")))
    (define functions (ir-program-functions ir))
    (check-equal? (map ir-function-name functions) '("ap" "main" "ap2" "block@test.agc:8:16"))
    (define block (list-ref functions 3))
    (check-equal? (list (ir-function-params block) (ir-function-captures block)) '(1 2))
    (define (ops function kinds)
      (for/list ([item (in-list (ir-function-body function))]
                 #:when (and (ir-instr? item) (memq (ir-instr-op item) kinds)))
        (cons (ir-instr-op item) (ir-instr-args item))))
    (check-equal? (ops (list-ref functions 0) '(call call-value tail-call return))
                  '((call-value 1 1) (return 1) (return 1)))
    (check-equal? (ops (list-ref functions 1) '(move closure))
                  '((move 5 1) (move 6 0) (closure 5 3) (move 4 5) (move 2 3) (closure 4 2) (move 3 4) (move 3 2)))
    (define program (ir->bytecode ir))
    (define encoded (list-ref (bc-program-functions program) 3))
    (check-equal? (list (bc-function-params encoded) (bc-function-captures encoded)) '(1 2))
    (check-equal? (bc-program-builtins program) '(("List.map" . 2) ("puts" . 1))))

  (test-case "for over a range literal counts without a Range value"
    (define ir
      (lower-text (string-append
                   "def main() -> Void\n  for i in 0...3\n    puts(i)\n  end\n"
                   "  r = 1..2\n  for j in r\n    puts(j)\n  end\nend\n")))
    (define main (car (ir-program-functions ir)))
    (define ops (for/list ([item (in-list (ir-function-body main))]
                           #:when (and (ir-instr? item) (memq (ir-instr-op item) '(range range-bounds sub-i add-i))))
                  (ir-instr-op item)))
    (check-equal? ops '(sub-i add-i range range-bounds add-i))
    (check-false (diagnostic? (ir->bytecode ir))))

  (test-case "a struct update is one struct-with; sites that change the same fields share a table entry"
    (define program
      (ir->bytecode
       (lower-text (string-append
                    "struct P\n  a: Int\n  b: Int\n  c: Int\nend\n\n"
                    "def main() -> Void\n  p = P(a: 1, b: 2, c: 3)\n  q = p.with(c: 4, a: 5)\n"
                    "  r = q.with(a: 6, c: 7)\n  s = r.with(b: 8)\n  puts(s)\nend\n"))))
    ;; (struct index . field indexes), fields in increasing order whatever the order written.
    (check-equal? (bc-program-updates program) '((0 0 2) (0 1)))
    (define main (list-ref (bc-program-functions program) (bc-program-entry program)))
    (define with-op (index-of opcodes 'struct-with))
    (define updates
      (for/list ([instr (in-vector (bc-function-code main))] #:when (= (first instr) with-op))
        (fourth instr)))
    (check-equal? updates '(0 0 1))
    (check-false (member (index-of opcodes 'field)
                         (for/list ([instr (in-vector (bc-function-code main))]) (first instr)))))

  (test-case "module constants: literals are inlined, the others get a slot, a function and a place in <start>"
    (define program
      (ir->bytecode
       (lower-linked-text
        (string-append
         "SIZE = 4\nTABLE = {\"a\": SIZE}\nSQUARES = [1, 2].map do |n| n * SIZE end\nLATE = SQUARES.size\n"
         "UNUSED = [9]\n\n"
         "def main() -> Void\n  puts(\"#{TABLE} #{SIZE}\")\n  [1].each do |n|\n    puts(n + LATE)\n  end\nend\n\n"
         "def unreachable() -> Int\n  return UNUSED.size\nend\n"))))
    (define names (map bc-function-name (bc-program-functions program)))
    ;; Declared functions, the kept constants in initialization order, <start>, then the blocks in the
    ;; order they are lowered: the functions first, then the constants.
    (check-equal? (take names 6) '("main" "unreachable" "TABLE" "SQUARES" "LATE" "<start>"))
    (check-equal? (length names) 8)
    ;; The block of main (line 9) is lowered before the block of SQUARES (line 3).
    (check-equal? (drop names 6) '("block@test.agc:9:12" "block@test.agc:3:22"))
    (check-equal? (bc-program-entry program) 5)
    ;; Slots follow the initialization order: TABLE, SQUARES, LATE, and UNUSED, which only the unreachable
    ;; function reads (a slot nothing writes). SIZE is a literal and has none.
    (check-equal? (bc-program-globals program) 4)
    (define start (list-ref (bc-program-functions program) 5))
    (define (ops function) (for/list ([instr (in-vector (bc-function-code function))]) (first instr)))
    (define set-op (index-of opcodes 'global-set))
    (define call-op (index-of opcodes 'call))
    (check-equal? (for/list ([instr (in-vector (bc-function-code start))] #:when (= (first instr) set-op))
                    (list (second instr) (+ (third instr) (* 65536 (fourth instr)))))
                  '((0 0) (0 1) (0 2)))
    (check-equal? (for/list ([instr (in-vector (bc-function-code start))] #:when (= (first instr) call-op))
                    (third instr))
                  '(2 3 4))
    (check-equal? (count (lambda (op) (= op (index-of opcodes 'tail-call))) (ops start)) 1)
    ;; Only <start> writes a slot.
    (for ([function (in-list (bc-program-functions program))] #:unless (eq? function start))
      (check-false (member set-op (ops function)) (bc-function-name function)))
    ;; A literal constant is a CONST in the reader: no GLOBAL reads SIZE (slot 0 is TABLE, read once in main).
    (define main (car (bc-program-functions program)))
    (check-equal? (count (lambda (op) (= op (index-of opcodes 'global))) (ops main)) 1))

  (test-case "a constant read only by an unreachable function still gets a slot and <start>"
    (define program
      (ir->bytecode
       (lower-linked-text "UNUSED = [9]\n\ndef main() -> Void\n  puts(1)\nend\n\ndef never() -> Int\n  return UNUSED.size\nend\n")))
    (check-equal? (map bc-function-name (bc-program-functions program)) '("main" "never" "<start>"))
    (check-equal? (bc-program-globals program) 1)
    (check-equal? (bc-program-entry program) 2))

  (test-case "a program without constants keeps main as its entry and writes no slots"
    (define program (ir->bytecode (lower-text "def main() -> Void\n  puts(1)\nend\n")))
    (check-equal? (bc-program-globals program) 0)
    (check-equal? (map bc-function-name (bc-program-functions program)) '("main"))
    (check-equal? (bc-program-entry program) 0)
    ;; A program that only has literal constants has no slot and no <start> either.
    (define literals (ir->bytecode (lower-linked-text "SIZE = 4\nNAME = \"x\"\n\ndef main() -> Void\n  puts(\"#{NAME}#{SIZE}\")\nend\n")))
    (check-equal? (bc-program-globals literals) 0)
    (check-equal? (map bc-function-name (bc-program-functions literals)) '("main")))

  (test-case "more than 65,535 slots is BYTECODE-LIMIT"
    (define ir (lower-linked-text "ITEMS = [1]\n\ndef main() -> Void\n  puts(ITEMS.size)\nend\n"))
    (check-true (bc-program? (ir->bytecode (struct-copy ir-program ir [globals 65535]))))
    (define over (ir->bytecode (struct-copy ir-program ir [globals 65536])))
    (check-equal? (diagnostic-code over) 'BYTECODE-LIMIT))

  (test-case "opcode numbers match vm/value.h"
    (define names
      (for/list ([match (in-list (regexp-match* #px"AGC_OP_([A-Z_]+)" (file->string vm-header)
                                                #:match-select cadr))]
                 #:unless (equal? match "COUNT"))
        match))
    (check-equal? names
                  (for/list ([op (in-list opcodes)])
                    (string-replace (string-upcase (symbol->string op)) "-" "_"))))

  (test-case "JSON field types are written only for programs that use them, up to 1024 nested levels"
    (define (nested n) (for/fold ([type 'Int]) ([_ (in-range n)]) (list 'List type)))
    (define (source-type n) (string-append (string-append* (make-list n "List[")) "Int" (make-string n #\])))
    ; The parser stops at 1000 levels of nesting, so a deeper type cannot be written in source: the used
    ; case sets the JSON field type of the struct in the IR. The unused case keeps a deep type in source.
    (define (program source-n use? ir-n)
      (define ir (lower-text (format "struct Deep\n  xs: ~a\nend\n\ndef main() -> Void\n  ~a\nend\n"
                                     (source-type source-n) (if use? "puts(JSON.schema(Deep))" "puts(1)"))))
      (struct-copy ir-program ir
                   [structs (for/list ([entry (in-list (ir-program-structs ir))])
                              (if (and use? (equal? (ir-struct-name entry) "Deep"))
                                  (struct-copy ir-struct entry [types (list (nested ir-n))])
                                  entry))]))
    (check-pred bc-program? (ir->bytecode (program 1 #t 1024)))
    (define deep (ir->bytecode (program 1 #t 1025)))
    (check-equal? (and (diagnostic? deep) (diagnostic-code deep)) 'BYTECODE-LIMIT)
    (define plain (ir->bytecode (program 900 #f 0)))
    (check-equal? (vector-length (bc-program-types plain)) 0)))
