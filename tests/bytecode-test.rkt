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
                    (string-replace (string-upcase (symbol->string op)) "-" "_")))))
