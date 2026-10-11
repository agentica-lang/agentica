#lang racket

(require (except-in rackunit check)
         json
         racket/os
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
(define vm-binary (getenv "AGENTICA_VM_BINARY"))
(define linux? (eq? (system-type 'os*) 'linux))
(define vm-file
  (if vm-binary
      (path->complete-path vm-binary root)
      (build-path root "dist" (if (eq? (system-type) 'windows) "agentica-vm.exe" "agentica-vm"))))
(define full-sweep-limit 2000)

(define (vm-built?)
  (define make (find-executable-path "make"))
  (define built?
    (if vm-binary
        (file-exists? vm-file)
        (and make
             (parameterize ([current-directory root])
               (system* make "-s" "vm")))))
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

(define (run-racket checked limit [style 'plain])
  (define out (open-output-string))
  (define err (open-output-string))
  (define result (evaluate checked #:out out #:err err #:in (open-input-string "") #:max-steps limit))
  (define text
    (cond
      [(not (diagnostic? result)) ""]
      [(eq? style 'ai) (format-diagnostic-ai result)]
      [(eq? style 'json) (jsexpr->string (diagnostic->jsexpr result))]
      [else (format-diagnostic result)]))
  (list (if (diagnostic? result) 1 0)
        (get-output-string out)
        (string-append (get-output-string err) (if (diagnostic? result) (string-append text "\n") ""))))

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

(define (run-vm bytecode limit #:style [style 'plain] . extra)
  (apply run-process vm-file
         (append (if limit (list "--max-steps" (number->string limit)) '())
                 (case style [(ai) '("--ai")] [(json) '("--json")] [else '()])
                 (list "--" (path->string bytecode))
                 extra)))

(define (cli-environment temp vm)
  (define env (environment-variables-copy (current-environment-variables)))
  (environment-variables-set! env #"TMPDIR" (path->bytes temp))
  (environment-variables-set! env #"AGENTICA_VM" (path->bytes vm))
  env)

(define (run-cli temp #:vm [vm vm-file] . arguments)
  (parameterize ([current-environment-variables (cli-environment temp vm)])
    (apply run-process (find-system-path 'exec-file) (path->string main-file) arguments)))

(define (run-cli-in-process temp . arguments)
  (define out (open-output-string))
  (define err (open-output-string))
  (define status
    (let/ec escape
      (parameterize ([current-environment-variables (cli-environment temp vm-file)]
                     [current-namespace (make-base-namespace)]
                     [current-command-line-arguments (list->vector arguments)]
                     [current-input-port (open-input-string "")]
                     [current-output-port out]
                     [current-error-port err]
                     [exit-handler escape])
        (dynamic-require `(submod ,main-file main) #f)
        0)))
  (list status (get-output-string out) (get-output-string err)))

(define (bytecode-files directory)
  (for/list ([file (in-list (directory-list directory))]
             #:when (path-has-extension? file #".agcb"))
    file))

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
          (test-case (format "~a matches the evaluator in every diagnostic format" name)
            (for ([style (in-list '(plain ai json))])
              (check-equal? (run-vm bytecode #f #:style style) (run-racket checked #f style)
                            (format "~a ~a" name style))))
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
          (check-equal? (first (run-process vm-file "--ai" "--ai" "--" (path->string bytecode))) 2)
          (check-equal? (first (run-process vm-file "--max-steps" "5" "--max-steps" "5" "--" (path->string bytecode))) 2)
          (define limited (run-process vm-file "--max-steps" "1" "--ai" "--json" "--" (path->string bytecode)))
          (check-equal? (first limited) 1)
          (check-equal? (hash-ref (string->jsexpr (third limited)) 'code) "RUNTIME-STEP-LIMIT")
          (check-equal? (third (run-process vm-file "--json" "--" (path->string bytecode) "--ai")) "")
          (define unicode-name (build-path work "cálculo-λ-日本-𝔸.agcb"))
          (copy-file bytecode unicode-name)
          (check-equal? (run-vm unicode-name #f) (run-vm bytecode #f))
          (check-equal? (first (run-process vm-file "--" (path->string work))) 2)
          (define bad (build-path work "bad.agcb"))
          (call-with-output-file bad (lambda (out) (write-bytes #"AGCB" out)))
          (define rejected (run-process vm-file "--" (path->string bad)))
          (check-equal? (first rejected) 2)
          (check-true (string-prefix? (third rejected) "agentica-vm: invalid bytecode: ")))

        (when linux?
          (test-case "agentica --vm gives the evaluator's stdout, stderr and exit code"
            (define temp (make-temporary-directory "agentica-cli~a"))
            (define (same . arguments)
              (define on-vm (apply run-cli temp "--vm" arguments))
              (check-equal? on-vm (apply run-cli temp arguments) (format "~a" arguments))
              (check-equal? (bytecode-files temp) '() (format "~a leaves no bytecode" arguments))
              on-vm)
            (dynamic-wind
              void
              (lambda ()
                (for* ([name (in-list '("calls.agc" "division-by-zero.agc"))]
                       [style (in-list '(() ("--ai") ("--json")))])
                  (apply same (append style (list (path->string (build-path fixtures name))))))
                (define calls (path->string (build-path fixtures "calls.agc")))
                (check-equal? (first (same "--max-steps" "3" calls)) 1)
                (check-equal? (first (same calls "first" "--allow-run" "--json")) 0)
                (define unsupported (build-path temp "args.agc"))
                (display-to-file "def main() -> Void\n  puts(System.args().size.to_s)\nend\n\n" unsupported)
                (define lowered (run-cli temp "--vm" "--json" (path->string unsupported)))
                (check-equal? (first lowered) 1)
                (check-equal? (hash-ref (string->jsexpr (third lowered)) 'code) "LOWER-UNSUPPORTED")
                (delete-file unsupported)
                (check-equal? (first (run-cli temp "--vm" "--allow-run" calls)) 2)
                (check-equal? (first (run-cli temp "--vm" "--max-steps" "0" calls)) 2)
                (define missing (run-cli temp #:vm (build-path temp "no-vm") "--vm" calls))
                (check-equal? (first missing) 2)
                (define plain (build-path temp "plain-vm"))
                (copy-file vm-file plain)
                (file-or-directory-permissions plain #o644)
                (check-equal? (first (run-cli temp #:vm plain "--vm" calls)) 2)
                (delete-file plain)
                (check-equal? (run-cli-in-process temp "--vm" calls) (run-cli temp calls))
                (check-equal? (directory-list temp) '()))
              (lambda () (delete-directory/files temp))))

          (test-case "the hidden --driver-pid flag loads only a private input and then deletes it"
            (define bytecode (build-path work "calls.agcb"))
            (define copy (build-path work "driver-copy.agcb"))
            (define (driven pid)
              (run-process vm-file "--driver-pid" (number->string pid) "--" (path->string copy)))
            (copy-file bytecode copy)
            (file-or-directory-permissions copy #o600)
            (check-equal? (driven (getpid)) (run-vm bytecode #f))
            (check-false (file-exists? copy))
            (copy-file bytecode copy)
            (file-or-directory-permissions copy #o644)
            (check-equal? (first (driven (getpid))) 2)
            (check-true (file-exists? copy))
            (file-or-directory-permissions copy #o600)
            (define mismatch (driven (add1 (getpid))))
            (check-equal? (first mismatch) 2)
            (check-true (file-exists? copy))
            (define link (build-path work "driver-link.agcb"))
            (make-file-or-directory-link copy link)
            (check-equal? (first (run-process vm-file "--driver-pid" (number->string (getpid)) "--" (path->string link))) 2)
            (check-true (file-exists? copy))
            (delete-file link)
            (delete-file copy)))

        (test-case "deep tail calls run on the VM but overflow on the evaluator"
          (define program (build-path work "deep-tail.agc"))
          (display-to-file
           (string-append
            "def loop(n: Int, acc: Int) -> Int\n  if n == 0\n    return acc\n  end\n  return loop(n - 1, acc + 1)\nend\n\n"
            "def even(n: Int) -> Bool\n  if n == 0\n    return true\n  end\n  return odd(n - 1)\nend\n\n"
            "def odd(n: Int) -> Bool\n  if n == 0\n    return false\n  end\n  return even(n - 1)\nend\n\n"
            "def main() -> Void\n  puts(loop(1000000, 0))\n  puts(even(1000001))\nend\n")
           program)
          (define bytecode (build-path work "deep-tail.agcb"))
          (compile-file program bytecode)
          (check-equal? (run-vm bytecode #f) (list 0 "1000000\nfalse\n" ""))
          (define racket (run-racket (front-end program) #f))
          (check-equal? (first racket) 1)
          (check-true (string-contains? (third racket) "error[RUNTIME-STACK-OVERFLOW]")))

        (test-case "a CRLF program under a non-ASCII path matches the evaluator"
          (define folder (build-path work "dír-λ-𝔸"))
          (make-directory folder)
          (define program (build-path folder "división-日本.agc"))
          (define text (file->string (build-path fixtures "division-by-zero.agc")))
          (call-with-output-file program
            (lambda (out) (write-string (string-replace text "\n" "\r\n") out)))
          (define bytecode (build-path folder "división-日本.agcb"))
          (compile-file program bytecode)
          (define checked (front-end program))
          (for ([style (in-list '(plain ai json))])
            (check-equal? (run-vm bytecode #f #:style style) (run-racket checked #f style)))
          (for ([limit (in-list (list 1 (sub1 (total-steps checked)) (total-steps checked)))])
            (check-equal? (run-vm bytecode limit) (run-racket checked limit)))))
      (lambda () (delete-directory/files work)))))
