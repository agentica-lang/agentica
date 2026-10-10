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

(define-runtime-path main-file "../src/main.rkt")
(define-runtime-path vm-header "../vm/agc.h")
(define-runtime-path unicode-data "../vm/unicode_data.c")
(define-runtime-path gen-unicode "../vm/gen-unicode.rkt")

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
  (test-case "adjacent steps merge into one STEP with one span each"
    (define program (ir->bytecode (lower-text "def main() -> Void\n  puts(\"hi\")\nend\n")))
    (define main (list-ref (bc-program-functions program) (bc-program-entry program)))
    (check-equal? (vector-ref (bc-function-code main) 0)
                  (list (index-of opcodes 'step) 3 0 0)))

  (test-case "opcode numbers match vm/agc.h"
    (define names
      (for/list ([match (in-list (regexp-match* #px"AGC_OP_([A-Z_]+)" (file->string vm-header)
                                                #:match-select cadr))]
                 #:unless (equal? match "COUNT"))
        match))
    (check-equal? names
                  (for/list ([op (in-list opcodes)])
                    (string-replace (string-upcase (symbol->string op)) "-" "_"))))

  (test-case "lowering rejects programs outside the VM subset"
    (define (unsupported-at text)
      (define problem (lower-text text))
      (check-true (diagnostic? problem))
      (check-equal? (diagnostic-code problem) 'LOWER-UNSUPPORTED)
      (define start (source-span-start (diagnostic-span problem)))
      (list (source-position-line start) (source-position-column start)))
    (check-equal? (unsupported-at "def main() -> Void\n  names = [\"Ana\"]\n  puts(names)\nend\n") '(2 11))
    (check-equal? (unsupported-at "def main() -> Void\n  for x in [1, 2]\n    puts(x)\n  end\nend\n") '(2 3))
    (check-equal? (unsupported-at "def show(xs: List[Int]) -> Void\n  print(xs)\nend\n\ndef main() -> Void\n  show([1])\nend\n")
                  '(2 9))
    (check-equal? (unsupported-at "def show(xs: List[Int]) -> Void\n  puts(\"#{xs}\")\n  puts(xs.inspect)\nend\n\ndef main() -> Void\nend\n")
                  '(2 11))
    (check-equal? (unsupported-at "def show(xs: List[Int]) -> Void\n  puts(xs.inspect)\nend\n\ndef main() -> Void\nend\n")
                  '(2 8))
    (check-equal? (unsupported-at "def main() -> Void\n  puts(\"abc\".length)\nend\n") '(2 8)))

  (test-case "vm/unicode_data.c is what vm/gen-unicode.rkt generates"
    (check-equal? ((dynamic-require gen-unicode 'unicode-data-text)) (file->string unicode-data)))

  (test-case "compile exits 1 on unsupported code and 2 on an unwritable output"
    (define work (make-temporary-directory "agentica-compile~a"))
    (dynamic-wind
      void
      (lambda ()
        (define unsupported (path->string (build-path work "lists.agc")))
        (display-to-file "def main() -> Void\n  names = [\"Ana\"]\n  puts(names)\nend\n" unsupported)
        (define rejected (cli "compile" unsupported "-o" (path->string (build-path work "out.agcb"))))
        (check-equal? (first rejected) 1)
        (check-true (string-contains? (third rejected) "error[LOWER-UNSUPPORTED]"))
        (define supported (path->string (build-path work "hello.agc")))
        (display-to-file "def main() -> Void\n  puts(\"hi\")\nend\n" supported)
        (define unwritable (cli "compile" supported "-o" (path->string (build-path work "missing" "out.agcb"))))
        (check-equal? (first unwritable) 2))
      (lambda () (delete-directory/files work)))))
