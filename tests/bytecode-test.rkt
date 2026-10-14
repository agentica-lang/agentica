#lang racket

(require (except-in rackunit check)
         racket/runtime-path
         "../src/builtins.rkt"
         "../src/bytecode.rkt"
         "../src/checker.rkt"
         "../src/diagnostic.rkt"
         "../src/lexer.rkt"
         "../src/lower.rkt"
         "../src/parser.rkt"
         "../src/source.rkt")

(define-runtime-path main-file "../src/main.rkt")
(define-runtime-path vm-header "../vm/value.h")

(for ([name '(#"AGENTICA_VM_TRACE" #"AGENTICA_VM_TRACE_FILE" #"AGENTICA_FLUSH_TIMEOUT_MS")])
  (environment-variables-set! (current-environment-variables) name #f))

(define (lower-text text)
  (define types (make-hasheq))
  (define checked (check (parse (lex (source "test.agc" text))) #:types types))
  (when (diagnostic? checked) (error 'bytecode-test "~a" (format-diagnostic checked)))
  (lower checked types))

(define (cli . arguments)
  (define-values (process out in err)
    (apply subprocess #f #f #f (find-system-path 'exec-file) (path->string main-file) arguments))
  (close-output-port in)
  (define stderr-text #f)
  (define reader (thread (lambda () (set! stderr-text (port->string err)))))
  (define stdout-text (port->string out))
  (thread-wait reader)
  (close-input-port out)
  (close-input-port err)
  (subprocess-wait process)
  (list (subprocess-status process) stdout-text stderr-text))

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
    (define (nested n) (string-append (string-append* (make-list n "List[")) "Int" (make-string n #\])))
    (define (program n use?)
      (format "struct Deep\n  xs: ~a\nend\n\ndef main() -> Void\n  ~a\nend\n"
              (nested n) (if use? "puts(JSON.schema(Deep))" "puts(1)")))
    (check-pred bc-program? (ir->bytecode (lower-text (program 1024 #t))))
    (define deep (ir->bytecode (lower-text (program 1025 #t))))
    (check-equal? (and (diagnostic? deep) (diagnostic-code deep)) 'BYTECODE-LIMIT)
    (define plain (ir->bytecode (lower-text (program 1025 #f))))
    (check-equal? (vector-length (bc-program-types plain)) 0))

  (test-case "compile exits 1 on a diagnostic and 2 on an unwritable output"
    (define work (make-temporary-directory "agentica-compile~a"))
    (dynamic-wind
      void
      (lambda ()
        (define rejected-file (path->string (build-path work "file.agc")))
        (display-to-file "def main() -> Void\n  c = HTTP.client_options()\nend\n" rejected-file)
        (define rejected (cli "compile" rejected-file "-o" (path->string (build-path work "out.agcb"))))
        (check-equal? (first rejected) 1)
        (check-true (string-contains? (third rejected) "error[CHECK-UNKNOWN-NAME]"))
        (check-false (file-exists? (build-path work "out.agcb")))
        (define supported (path->string (build-path work "hello.agc")))
        (display-to-file "def main() -> Void\n  puts(\"hi\")\nend\n" supported)
        (define unwritable (cli "compile" supported "-o" (path->string (build-path work "missing" "out.agcb"))))
        (check-equal? (first unwritable) 2))
      (lambda () (delete-directory/files work)))))
