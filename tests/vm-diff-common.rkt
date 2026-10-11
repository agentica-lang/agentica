#lang racket

(require (except-in rackunit check)
         json
         racket/os
         racket/runtime-path
         "cli-in-process.rkt"
         "../src/bytecode.rkt"
         "../src/checker.rkt"
         "../src/diagnostic.rkt"
         "../src/evaluator.rkt"
         "../src/lexer.rkt"
         "../src/lower.rkt"
         "../src/modules.rkt"
         "../src/parser.rkt"
         "../src/source.rkt")

(provide shard-count
         run-shard)

(define-runtime-path root "..")
(define-runtime-path fixtures "fixtures/vm")
(define-runtime-path main-file "../src/main.rkt")
(define-runtime-path tests-directory ".")
(define make-lock-wait 900)
(define vm-binary (getenv "AGENTICA_VM_BINARY"))
(define linux? (eq? (system-type 'os*) 'linux))
(define vm-file
  (if vm-binary
      (path->complete-path vm-binary root)
      (build-path root "dist" (if (eq? (system-type) 'windows) "agentica-vm.exe" "agentica-vm"))))
(define full-sweep-limit 2000)
(define shard-count 4)
(define heavy-fixtures
  '(("tail-calls.agc" . 1) ("stack-overflow.agc" . 2) ("map-large.agc" . 2) ("enums-case.agc" . 2)
    ("callback-overflow.agc" . 3) ("results.agc" . 3) ("list-chunks.agc" . 3)))
(define light-shard-rotation '(2 3 4 3))
(define extras-shard 4)
(define fixture-input (make-parameter #""))
(define fixture-args (make-parameter '()))
(define fixture-seed (make-parameter #f))

(define (exit-status code)
  (if (and (exact-integer? code) (<= 1 code 255)) code 0))

(define (vm-built?)
  (define make (find-executable-path "make"))
  (define (make-vm)
    (define lock (build-path root "build" "vm-diff-make.lock"))
    (make-directory* (build-path root "build"))
    (define deadline (+ (current-inexact-milliseconds) (* 1000 make-lock-wait)))
    (let retry ()
      (define result
        (call-with-file-lock/timeout
         lock 'exclusive
         (lambda () (if (parameterize ([current-directory root]) (system* make "-s" "vm")) 'built 'failed))
         (lambda () 'busy)
         #:max-delay 0.2))
      (cond
        [(eq? result 'built) #t]
        [(and (eq? result 'busy) (< (current-inexact-milliseconds) deadline)) (retry)]
        [else #f])))
  (define built?
    (if vm-binary
        (file-exists? vm-file)
        (and make (make-vm))))
  (cond
    [built? #t]
    [(getenv "AGENTICA_REQUIRE_VM") (error 'vm-diff "the VM must build when AGENTICA_REQUIRE_VM is set")]
    [else (displayln "SKIP VM differential tests: make vm failed") #f]))

(define (front-end path #:types [types #f])
  (define name (path->string path))
  (define tokens (lex (source name (file->string path))))
  (define tree (if (diagnostic? tokens) tokens (parse tokens)))
  (define linked (if (diagnostic? tree) tree (link-program tree name)))
  (define checked (if (diagnostic? linked) linked (check linked #:types types)))
  (when (diagnostic? checked) (error 'vm-diff "~a" (format-diagnostic checked)))
  checked)

(define (run-racket checked limit [style 'plain])
  (define out (open-output-string))
  (define err (open-output-string))
  (define result (evaluate checked #:out out #:err err #:in (open-input-bytes (fixture-input))
                           #:args (fixture-args) #:max-steps limit #:seed (fixture-seed)))
  (define text
    (cond
      [(not (diagnostic? result)) ""]
      [(eq? style 'ai) (format-diagnostic-ai result)]
      [(eq? style 'json) (jsexpr->string (diagnostic->jsexpr result))]
      [else (format-diagnostic result)]))
  (list (cond [(diagnostic? result) 1] [(exit-code? result) (exit-status (exit-code-code result))] [else 0])
        (get-output-string out)
        (string-append (get-output-string err) (if (diagnostic? result) (string-append text "\n") ""))))

(define (run-process program #:input [input #""] . arguments)
  (define-values (process out in err) (apply subprocess #f #f #f program arguments))
  (define writer
    (thread (lambda ()
              (with-handlers ([exn:fail? void]) (write-bytes input in))
              (with-handlers ([exn:fail? void]) (close-output-port in)))))
  (define stderr #f)
  (define reader (thread (lambda () (set! stderr (port->string err)))))
  (define stdout (port->string out))
  (thread-wait reader)
  (thread-wait writer)
  (close-input-port out)
  (close-input-port err)
  (subprocess-wait process)
  (list (subprocess-status process) stdout stderr))

(define (run-vm bytecode limit #:style [style 'plain] . extra)
  (apply run-process vm-file #:input (fixture-input)
         (append (limit-options limit)
                 (seed-options)
                 (style-options style)
                 (list "--" (path->string bytecode))
                 (map string->bytes/utf-8 (fixture-args))
                 extra)))

(define (cli-environment temp vm)
  (define env (environment-variables-copy (current-environment-variables)))
  (environment-variables-set! env #"TMPDIR" (path->bytes temp))
  (environment-variables-set! env #"AGENTICA_VM" (path->bytes vm))
  env)

(define (run-cli temp #:vm [vm vm-file] #:input [input #""] . arguments)
  (parameterize ([current-environment-variables (cli-environment temp vm)])
    (apply run-process (find-system-path 'exec-file) (path->string main-file) #:input input arguments)))

(define (run-cli-in-process temp #:input [input #""] #:port [port (open-input-bytes input)] . arguments)
  (apply run-main-in-process #:environment (cli-environment temp vm-file) #:port port arguments))

(define (bytecode-files directory)
  (for/list ([file (in-list (directory-list directory))]
             #:when (path-has-extension? file #".agcb"))
    file))

(define (compile-file path output)
  (define types (make-hasheq))
  (define checked (front-end path #:types types))
  (define (ok value)
    (when (diagnostic? value) (error 'vm-diff "compile failed: ~a" (format-diagnostic value)))
    value)
  (define data (ok (write-bytecode (ok (ir->bytecode (ok (lower checked types)))))))
  (call-with-output-file output #:exists 'truncate/replace
    (lambda (out) (void (write-bytes data out)))))

(define (shell-quote text)
  (string-append "'" (string-replace text "'" "'\\''") "'"))

(define (style-options style)
  (case style [(ai) '("--ai")] [(json) '("--json")] [else '()]))

(define (seed-options)
  (if (fixture-seed) (list "--seed" (number->string (fixture-seed))) '()))

(define (limit-options limit)
  (if limit (list "--max-steps" (number->string limit)) '()))

(define (vm-batch name bytecode directory option-lists during)
  (define process #f)
  (define out #f)
  (define err #f)
  (dynamic-wind
    void
    (lambda ()
      (make-directory* directory)
      (define input (build-path directory "stdin"))
      (call-with-output-file input (lambda (port) (void (write-bytes (fixture-input) port))))
      (define tail
        (string-join (map shell-quote (append (seed-options) (list "--" (path->string bytecode)) (fixture-args)))))
      (define script (build-path directory "run.sh"))
      (call-with-output-file script
        (lambda (port)
          (write-string "exec 2>/dev/null\n" port)
          (for ([options (in-list option-lists)] [index (in-naturals)])
            (define base (path->string (build-path directory (number->string index))))
            (write-string
             (format "~a ~a ~a < ~a > ~a 2> ~a\necho $? > ~a\n"
                     (shell-quote (path->string vm-file)) (string-join (map shell-quote options)) tail
                     (shell-quote (path->string input)) (shell-quote (string-append base ".out"))
                     (shell-quote (string-append base ".err")) (shell-quote (string-append base ".status")))
             port))))
      (define-values (started stdout-port stdin-port stderr-port)
        (parameterize ([subprocess-group-enabled #t])
          (subprocess #f #f #f (or (find-executable-path "sh") "/bin/sh") (path->string script))))
      (set! process started)
      (set! out stdout-port)
      (set! err stderr-port)
      (close-output-port stdin-port)
      (define expected (during))
      (define stdout (port->string out))
      (define stderr (port->string err))
      (subprocess-wait process)
      (unless (and (zero? (subprocess-status process)) (equal? stdout "") (equal? stderr ""))
        (error 'vm-diff "~a: VM batch failed: ~a ~a" name stdout stderr))
      (values
       (for/list ([index (in-range (length option-lists))])
         (define (part extension) (build-path directory (format "~a~a" index extension)))
         (list (string->number (string-trim (file->string (part ".status"))))
               (file->string (part ".out"))
               (file->string (part ".err"))))
       expected))
    (lambda ()
      (when process
        (when (eq? (subprocess-status process) 'running) (subprocess-kill process #t))
        (subprocess-wait process))
      (when out (close-input-port out))
      (when err (close-input-port err))
      (delete-directory/files directory #:must-exist? #f))))

(define (shard-of name light-index)
  (cond
    [(assoc name heavy-fixtures) => cdr]
    [else (list-ref light-shard-rotation (modulo light-index (length light-shard-rotation)))]))

(define (shard-assignment programs)
  (define light-index -1)
  (for/list ([program (in-list programs)])
    (define name (path->string (file-name-from-path program)))
    (cons program
          (shard-of name (if (assoc name heavy-fixtures)
                             -1
                             (begin (set! light-index (add1 light-index)) light-index))))))

(define (fixture-programs)
  (sort (for/list ([file (in-list (directory-list fixtures #:build? #t))]
                   #:when (path-has-extension? file #".agc"))
          file)
        path<?))

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

(define (run-fixture work program)
  (define name (path->string (file-name-from-path program)))
  (define bytecode (build-path work (path-replace-extension (file-name-from-path program) #".agcb")))
  (define runs (build-path work (format "~a-runs" name)))
  (compile-file program bytecode)
  (define checked (front-end program))
  (define (sidecar extension read-it default)
    (define file (path-replace-extension program extension))
    (if (file-exists? file) (read-it file) default))
  (define seeds (sidecar #".seeds" file->value '(#f)))
  (parameterize ([fixture-input (sidecar #".stdin" file->bytes #"")]
                 [fixture-args (sidecar #".args" file->value '())]
                 [fixture-seed (first seeds)])
    (for ([seed (in-list seeds)])
      (parameterize ([fixture-seed seed])
        (test-case (format "~a matches the evaluator in every diagnostic format (seed ~a)" name seed)
          (define styles '(plain ai json))
          (define-values (vm-results racket-results)
            (vm-batch name bytecode runs (map style-options styles)
                      (lambda () (for/list ([style (in-list styles)]) (run-racket checked #f style)))))
          (for ([style (in-list styles)] [on-vm (in-list vm-results)] [expected (in-list racket-results)])
            (check-equal? on-vm expected (format "~a ~a" name style))))))
    (test-case (format "~a matches under every --max-steps" name)
      (define limits (sweep-limits (total-steps checked)))
      (define-values (vm-results racket-results)
        (vm-batch name bytecode runs (map limit-options limits)
                  (lambda () (for/list ([limit (in-list limits)]) (run-racket checked limit)))))
      (for ([limit (in-list limits)] [on-vm (in-list vm-results)] [expected (in-list racket-results)])
        (check-equal? on-vm expected (format "~a --max-steps ~a" name limit))))))

(define (run-shard shard)
  (when (vm-built?)
    (define work (make-temporary-directory "agentica-vm~a"))
    (define assignment (shard-assignment (fixture-programs)))
    (dynamic-wind
      void
      (lambda ()
        (for ([entry (in-list assignment)] #:when (= (cdr entry) shard))
          (run-fixture work (car entry)))
        (when (= shard extras-shard)
          (run-extras work assignment)))
      (lambda () (delete-directory/files work)))))

(define (run-extras work assignment)
  (test-case "the shard tables name real fixtures and shards"
    (define names (map (lambda (entry) (path->string (file-name-from-path (car entry)))) assignment))
    (check-equal? (length (remove-duplicates (map car heavy-fixtures))) (length heavy-fixtures))
    (for ([heavy (in-list heavy-fixtures)])
      (check-not-false (member (car heavy) names) (car heavy))
      (check-true (<= 1 (cdr heavy) shard-count) (car heavy)))
    (for ([shard (in-list light-shard-rotation)])
      (check-true (<= 1 shard shard-count) (format "light shard ~a" shard)))
    (for ([shard (in-range 1 (add1 shard-count))])
      (define file (build-path tests-directory (format "vm-diff-~a-test.rkt" shard)))
      (check-true (and (file-exists? file)
                       (string-contains? (file->string file) (format "(run-shard ~a)" shard)))
                  (path->string file))))
  (for ([name (in-list '("calls" "system-args"))])
    (compile-file (build-path fixtures (string-append name ".agc"))
                  (build-path work (string-append name ".agcb"))))
  (test-case "compile-file writes the same bytes as the CLI compile"
    (for ([name (in-list '("imports" "io-gets" "enums-case"))])
      (define program (build-path fixtures (string-append name ".agc")))
      (define in-process (build-path work (string-append name "-in-process.agcb")))
      (define from-cli (build-path work (string-append name "-cli.agcb")))
      (compile-file program in-process)
      (define result (run-process (find-system-path 'exec-file) (path->string main-file)
                                  "compile" (path->string program) "-o" (path->string from-cli)))
      (check-equal? (first result) 0 (third result))
      (check-equal? (file->bytes in-process) (file->bytes from-cli) name)))
  (test-case "the VM reads piped stdin like the evaluator"
    (for ([name (in-list '("io-read" "io-rest"))])
      (define program (build-path fixtures (string-append name ".agc")))
      (define bytecode (build-path work (string-append name "-pipe.agcb")))
      (compile-file program bytecode)
      (parameterize ([fixture-input (file->bytes (build-path fixtures (string-append name ".stdin")))])
        (check-equal? (run-vm bytecode #f) (run-racket (front-end program) #f) name))))
  (test-case "unbounded range loops stop at --max-steps like the evaluator"
    (for ([program (in-list (directory-list (build-path fixtures "step-limited") #:build? #t))]
          #:when (path-has-extension? program #".agc"))
      (define name (path->string (file-name-from-path program)))
      (define bytecode (build-path work (path-replace-extension (file-name-from-path program) #".agcb")))
      (compile-file program bytecode)
      (define checked (front-end program))
      (for ([limit (in-list '(1 2 3 4 5 50 500))])
        (define expected (run-racket checked limit))
        (check-equal? (first expected) 1 (format "~a --max-steps ~a" name limit))
        (check-true (string-contains? (third expected) "RUNTIME-STEP-LIMIT") name)
        (check-equal? (run-vm bytecode limit) expected (format "~a --max-steps ~a" name limit)))))
  (test-case "the VM CLI checks options and stops parsing at the file"
    (define bytecode (build-path work "calls.agcb"))
    (check-equal? (first (run-vm bytecode #f "--max-steps" "1")) 0)
    (check-equal? (first (run-process vm-file "--max-steps" "0" "--" (path->string bytecode))) 2)
    (check-equal? (first (run-process vm-file "--bogus" "--" (path->string bytecode))) 2)
    (check-equal? (first (run-process vm-file "--ai" "--ai" "--" (path->string bytecode))) 2)
    (check-equal? (first (run-process vm-file "--max-steps" "5" "--max-steps" "5" "--" (path->string bytecode))) 2)
    (for ([seed (in-list '("-1" "2147483648" "1x" "" "99999999999999999999"))])
      (define rejected (run-process vm-file "--seed" seed "--" (path->string bytecode)))
      (check-equal? (first rejected) 2 seed)
      (check-equal? (third rejected) "agentica-vm: --seed needs an integer from 0 to 2147483647\n" seed))
    (check-equal? (first (run-process vm-file "--seed" "1" "--seed" "1" "--" (path->string bytecode))) 2)
    (check-equal? (first (run-process vm-file "--seed" "0002147483647" "--" (path->string bytecode))) 0)
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
          (display-to-file "def main() -> Void\n  puts(JSON.null)\nend\n\n" unsupported)
          (define lowered (run-cli temp "--vm" "--json" (path->string unsupported)))
          (check-equal? (first lowered) 1)
          (check-equal? (hash-ref (string->jsexpr (third lowered)) 'code) "LOWER-UNSUPPORTED")
          (delete-file unsupported)
          (check-equal? (first (run-cli temp "--vm" "--allow-run" calls)) 2)
          (define random (path->string (build-path fixtures "random.agc")))
          (check-equal? (first (same "--seed" "77" random)) 0)
          (check-equal? (first (same "--seed" "2147483648" random)) 2)
          (check-equal? (first (run-cli temp "--vm" "--max-steps" "0" calls)) 2)
          (define missing (run-cli temp #:vm (build-path temp "no-vm") "--vm" calls))
          (check-equal? (first missing) 2)
          (define plain (build-path temp "plain-vm"))
          (copy-file vm-file plain)
          (file-or-directory-permissions plain #o644)
          (check-equal? (first (run-cli temp #:vm plain "--vm" calls)) 2)
          (delete-file plain)
          (check-equal? (run-cli-in-process temp "--vm" calls) (run-cli temp calls))
          (define gets (path->string (build-path fixtures "io-gets.agc")))
          (define input (file->bytes (build-path fixtures "io-gets.stdin")))
          (define expected (run-cli temp #:input input gets))
          (check-equal? (run-cli temp #:input input "--vm" gets) expected)
          (check-equal? (run-cli-in-process temp #:input input "--vm" gets) expected)
          (define broken
            (make-input-port 'broken (lambda (_) (raise (exn:fail "read failed" (current-continuation-marks))))
                             #f void))
          (define failed (run-cli-in-process temp #:port broken "--vm" "--json" gets))
          (check-equal? (first failed) 1)
          (check-equal? (hash-ref (string->jsexpr (last (string-split (third failed) "\n"))) 'code)
                        "RUNTIME-INTERNAL")
          (check-equal? (first (same (path->string (build-path fixtures "system-exit.agc")))) 3)
          (same (path->string (build-path fixtures "system-args.agc")) "a" "" "λ 𝔸" "--json")
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

  (when linux?
    (test-case "the VM decodes invalid UTF-8 arguments like the evaluator in a UTF-8 locale"
      (define program (build-path fixtures "system-args.agc"))
      (define bytecode (build-path work "system-args.agcb"))
      (define arguments
        (list #"\xff\xfeZ" #"\xe2\x82A" #"\xed\xa0\x80z" #"a\xe2\x82" #"\xf0\x9f\x98" #"\xe0\x80"
              #"\xf0\x80\x80" #"\xed\xa0" #"\xf4\x90" #"\xc0\xaf" #"\xe2\x82\xe2\x82" #"\xe2\x82\xac"))
      (define env (environment-variables-copy (current-environment-variables)))
      (environment-variables-set! env #"LC_ALL" #"C.UTF-8")
      (parameterize ([current-environment-variables env])
        (check-equal? (apply run-process vm-file "--" (path->string bytecode) arguments)
                      (apply run-process (find-system-path 'exec-file) (path->string main-file)
                             (path->string program) arguments)))))

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

  (test-case "large generated input splits lines like the evaluator across buffer boundaries"
    (define program (build-path work "large-input.agc"))
    (display-to-file
     (string-append
      "def main() -> Void\n  count = 0\n  running = true\n  while running\n    case gets()\n"
      "      ok(line) -> puts(\"#{count}: #{line.inspect}\")\n"
      "      error(message) ->\n        puts(message)\n        running = false\n    end\n"
      "    count = count + 1\n  end\n  puts(count)\nend\n")
     program)
    (define bytecode (build-path work "large-input.agcb"))
    (compile-file program bytecode)
    (define checked (front-end program))
    (define (run-of n byte) (make-bytes n (char->integer byte)))
    (define input
      (bytes-append
       (run-of 65535 #\a) #"\xe2\x82\xac\n"
       (run-of 65535 #\b) #"\r\n"
       (run-of 65535 #\c) #"\rnext\n"
       (run-of 65534 #\d) #"\xf0\x9f\x98\x80\xff\xe2\x82\n"
       (apply bytes-append (for/list ([k (in-range 20000)]) (string->bytes/utf-8 (format "line ~a\r\n" k))))
       #"tail \xe2\x82"))
    (parameterize ([fixture-input input])
      (for ([limit (in-list '(#f 1 50 100000 400000))])
        (check-equal? (run-vm bytecode limit) (run-racket checked limit)
                      (format "large input --max-steps ~a" limit)))))

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
