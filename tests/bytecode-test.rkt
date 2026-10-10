#lang racket

(require (except-in rackunit check)
         racket/runtime-path
         "../src/bytecode.rkt"
         "../src/checker.rkt"
         "../src/diagnostic.rkt"
         "../src/lexer.rkt"
         "../src/lower.rkt"
         "../src/parser.rkt"
         "../src/source.rkt")

(define-runtime-path fixtures "fixtures/vm")

(define (lower-text text)
  (define types (make-hasheq))
  (define checked (check (parse (lex (source "test.agc" text))) #:types types))
  (when (diagnostic? checked) (error 'bytecode-test "~a" (format-diagnostic checked)))
  (lower checked types))

(module+ test
  (test-case "bytecode survives a write and read round trip"
    (for ([file (in-list (directory-list fixtures #:build? #t))]
          #:when (path-has-extension? file #".agc"))
      (define program (ir->bytecode (lower-text (file->string file))))
      (define data (write-bytecode program))
      (define read-back (read-bytecode data))
      (check-equal? read-back program (path->string file))
      (check-equal? (write-bytecode read-back) data (path->string file))))

  (test-case "adjacent steps merge into one STEP with one span each"
    (define program (ir->bytecode (lower-text "def main() -> Void\n  puts(\"hi\")\nend\n")))
    (define main (list-ref (bc-program-functions program) (bc-program-entry program)))
    (check-equal? (vector-ref (bc-function-code main) 0)
                  (list (index-of opcodes 'step) 3 0 0)))

  (test-case "lowering rejects programs outside the VM subset"
    (define problem
      (lower-text "def main() -> Void\n  name = \"Ana\"\n  puts(name)\nend\n"))
    (check-true (diagnostic? problem))
    (check-equal? (diagnostic-code problem) 'LOWER-UNSUPPORTED)
    (check-equal? (source-position-line (source-span-start (diagnostic-span problem))) 2)
    (define loop
      (lower-text "def main() -> Void\n  for x in [1, 2]\n    puts(x)\n  end\nend\n"))
    (check-equal? (diagnostic-code loop) 'LOWER-UNSUPPORTED)))
