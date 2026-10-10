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
    (define problem
      (lower-text "def main() -> Void\n  name = \"Ana\"\n  puts(name)\nend\n"))
    (check-true (diagnostic? problem))
    (check-equal? (diagnostic-code problem) 'LOWER-UNSUPPORTED)
    (check-equal? (source-position-line (source-span-start (diagnostic-span problem))) 2)
    (define loop
      (lower-text "def main() -> Void\n  for x in [1, 2]\n    puts(x)\n  end\nend\n"))
    (check-equal? (diagnostic-code loop) 'LOWER-UNSUPPORTED))

  (test-case "compile exits 1 on unsupported code and 2 on an unwritable output"
    (define work (make-temporary-directory "agentica-compile~a"))
    (dynamic-wind
      void
      (lambda ()
        (define unsupported (path->string (build-path work "strings.agc")))
        (display-to-file "def main() -> Void\n  name = \"Ana\"\n  puts(name)\nend\n" unsupported)
        (define rejected (cli "compile" unsupported "-o" (path->string (build-path work "out.agcb"))))
        (check-equal? (first rejected) 1)
        (check-true (string-contains? (third rejected) "error[LOWER-UNSUPPORTED]"))
        (define supported (path->string (build-path work "hello.agc")))
        (display-to-file "def main() -> Void\n  puts(\"hi\")\nend\n" supported)
        (define unwritable (cli "compile" supported "-o" (path->string (build-path work "missing" "out.agcb"))))
        (check-equal? (first unwritable) 2))
      (lambda () (delete-directory/files work)))))
