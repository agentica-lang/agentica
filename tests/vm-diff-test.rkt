#lang racket

(require (except-in rackunit check)
         racket/runtime-path
         "../src/checker.rkt"
         "../src/diagnostic.rkt"
         "../src/evaluator.rkt"
         "../src/lexer.rkt"
         "../src/modules.rkt"
         "../src/parser.rkt"
         "../src/source.rkt")

(define-runtime-path root "..")
(define-runtime-path fixtures "fixtures/vm")
(define-runtime-path main-file "../src/main.rkt")
(define vm-file (build-path root "dist" "agentica-vm"))
(define full-sweep-limit 2000)

(define (vm-built?)
  (define make (find-executable-path "make"))
  (define built?
    (and make
         (parameterize ([current-directory root])
           (system* make "-s" "vm"))))
  (cond
    [built? #t]
    [(getenv "AGENTICA_REQUIRE_VM") (error 'vm-diff-test "the VM must build when AGENTICA_REQUIRE_VM is set")]
    [else (displayln "SKIP VM differential tests: make vm failed") #f]))

(define (front-end path)
  (define name (path->string path))
  (define tokens (lex (source name (file->string path))))
  (define tree (if (diagnostic? tokens) tokens (parse tokens)))
  (define linked (if (diagnostic? tree) tree (link-program tree name)))
  (define checked (if (diagnostic? linked) linked (check linked)))
  (when (diagnostic? checked) (error 'vm-diff-test "~a" (format-diagnostic checked)))
  checked)

(define (run-racket checked limit)
  (define out (open-output-string))
  (define result (evaluate checked #:out out #:in (open-input-string "") #:max-steps limit))
  (list (if (diagnostic? result) 1 0)
        (get-output-string out)
        (if (diagnostic? result) (string-append (format-diagnostic result) "\n") "")))

(define (run-process program . arguments)
  (define-values (process out in err) (apply subprocess #f #f #f program arguments))
  (close-output-port in)
  (define stderr #f)
  (define reader (thread (lambda () (set! stderr (port->string err)))))
  (define stdout (port->string out))
  (thread-wait reader)
  (close-input-port out)
  (close-input-port err)
  (subprocess-wait process)
  (list (subprocess-status process) stdout stderr))

(define (run-vm bytecode limit . extra)
  (apply run-process vm-file
         (append (if limit (list "--max-steps" (number->string limit)) '())
                 (list "--" (path->string bytecode))
                 extra)))

(define (compile-file path output)
  (define result (run-process (find-system-path 'exec-file) (path->string main-file)
                              "compile" (path->string path) "-o" (path->string output)))
  (unless (zero? (first result)) (error 'vm-diff-test "compile failed: ~a" (third result))))

(define (step-limited? result)
  (string-contains? (third result) "error[RUNTIME-STEP-LIMIT]"))

(define (total-steps checked)
  (let search ([low 1] [high 1])
    (cond
      [(step-limited? (run-racket checked high)) (search high (* 2 high))]
      [(>= low high) high]
      [else
       (let narrow ([low low] [high high])
         (define middle (quotient (+ low high) 2))
         (cond
           [(>= low high) high]
           [(step-limited? (run-racket checked middle)) (narrow (add1 middle) high)]
           [else (narrow low middle)]))])))

(define (sweep-limits total)
  (if (<= total full-sweep-limit)
      (range 1 (add1 total))
      (remove-duplicates
       (append (range 1 301)
               (range 300 total (quotient total 50))
               (list (sub1 total) total)))))

(module+ test
  (when (vm-built?)
    (define work (make-temporary-directory "agentica-vm~a"))
    (define programs
      (sort (for/list ([file (in-list (directory-list fixtures #:build? #t))]
                       #:when (path-has-extension? file #".agc"))
              file)
            path<?))
    (dynamic-wind
      void
      (lambda ()
        (for ([program (in-list programs)])
          (define name (path->string (file-name-from-path program)))
          (define bytecode (build-path work (path-replace-extension (file-name-from-path program) #".agcb")))
          (compile-file program bytecode)
          (define checked (front-end program))
          (test-case (format "~a matches the evaluator" name)
            (check-equal? (run-vm bytecode #f) (run-racket checked #f) name))
          (test-case (format "~a matches under every --max-steps" name)
            (define total (total-steps checked))
            (for ([limit (in-list (sweep-limits total))])
              (check-equal? (run-vm bytecode limit) (run-racket checked limit)
                            (format "~a --max-steps ~a" name limit)))))

        (test-case "the VM CLI checks options and stops parsing at the file"
          (define bytecode (build-path work "calls.agcb"))
          (check-equal? (first (run-vm bytecode #f "--max-steps" "1")) 0)
          (check-equal? (first (run-process vm-file "--max-steps" "0" "--" (path->string bytecode))) 2)
          (check-equal? (first (run-process vm-file "--bogus" "--" (path->string bytecode))) 2)
          (define bad (build-path work "bad.agcb"))
          (call-with-output-file bad (lambda (out) (write-bytes #"AGCB" out)))
          (define rejected (run-process vm-file "--" (path->string bad)))
          (check-equal? (first rejected) 2)
          (check-true (string-prefix? (third rejected) "agentica-vm: invalid bytecode: "))))
      (lambda () (delete-directory/files work)))))
