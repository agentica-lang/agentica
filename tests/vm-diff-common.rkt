#lang racket

(require (except-in rackunit check)
         (only-in ffi/unsafe -> _fun _int get-ffi-obj)
         json
         racket/os
         racket/runtime-path
         rackunit/log
         "cli-in-process.rkt"
         "../src/bytecode.rkt"
         "../src/checker.rkt"
         "../src/diagnostic.rkt"
         "../src/lexer.rkt"
         "../src/lower.rkt"
         "../src/modules.rkt"
         "../src/parser.rkt"
         "../src/source.rkt")

(provide shard-count
         run-shard
         vm-file
         vm-built?
         compile-file
         run-process
         run-timeout
         fixture-arg
         fixture-selected?
         check-fixture-filter)

(define-runtime-path root "..")
(define-runtime-path fixtures "fixtures/vm")
(define-runtime-path main-file "../src/main.rkt")
(define-runtime-path tests-directory ".")
(define make-lock-wait 900)
(define run-timeout 60)
(define vm-binary (getenv "AGENTICA_VM_BINARY"))
(define linux? (eq? (system-type 'os*) 'linux))
(define timeout-program (and linux? (find-executable-path "timeout")))
(define vm-file
  (if vm-binary
      (path->complete-path vm-binary root)
      (build-path root "dist" (if (eq? (system-type) 'windows) "agentica-vm.exe" "agentica-vm"))))
(define unix-kill (get-ffi-obj "kill" #f (_fun _int _int -> _int) (lambda () #f)))
(define sigkill 9)
(define sigterm 15)
(define full-sweep-limit 200)
(define sweep-head 100)
(define sample-points 8)
(define sweep-mode (getenv "AGENTICA_SWEEP"))
(define sampled-sweep? (equal? sweep-mode "sampled"))
(unless (member sweep-mode '(#f "" "full" "sampled"))
  (error 'vm-diff "AGENTICA_SWEEP must be full or sampled, not ~s" sweep-mode))
(define runaway-limit 500)
(define vm-turn-steps 2000)
(define shard-count 8)

(for ([name '(#"AGENTICA_VM_TRACE" #"AGENTICA_VM_TRACE_FILE" #"AGENTICA_FLUSH_TIMEOUT_MS")])
  (environment-variables-set! (current-environment-variables) name #f))

(define heavy-fixtures
  '(("files-large.agc" . 1) ("process-limits.agc" . 1) ("tcp-exit.agc" . 2) ("json-decode-deep.agc" . 3) ("map-large.agc" . 3)
    ("http-server-slow.agc" . 4) ("task-concurrent.agc" . 5) ("tcp-limits.agc" . 5) ("tcp-tasks.agc" . 5)
    ("process-timeouts.agc" . 6) ("callback-overflow.agc" . 7) ("tcp-errors.agc" . 7)))
(define light-shard-rotation '(1 2 3 4 5 6 7))
(define extras-shard 8)
(define fixture-input (make-parameter #""))
(define fixture-args (make-parameter '()))
(define fixture-channel (make-parameter #f))
(define python (find-executable-path "python3"))
(define channel-run-file (build-path tests-directory "fixtures" "channel-run.py"))
(define fixture-allow-run (make-parameter #f))
(define allow-run-prefix "process-")
(define tmp-token "@tmp")
(define fixture-token "@fixtures/")
(define tmp-root (make-parameter #f))
(define tmp-count 0)

(define (vm-built? [tests "VM golden tests"])
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
    [else (printf "SKIP ~a: make vm failed\n" tests) #f]))

(define (front-end path #:types [types #f])
  (define name (path->string path))
  (define tokens (lex (source name (file->string path))))
  (define tree (if (diagnostic? tokens) tokens (parse tokens)))
  (define linked (if (diagnostic? tree) tree (link-program tree name)))
  (define checked (if (diagnostic? linked) linked (check linked #:types types)))
  (when (diagnostic? checked) (error 'vm-diff "~a" (format-diagnostic checked)))
  checked)

(define (fixture-arg argument)
  (if (string-prefix? argument fixture-token)
      (path->string (simplify-path (build-path tests-directory "fixtures" (substring argument (string-length fixture-token)))))
      argument))

(define (uses-tmp?)
  (and (member tmp-token (fixture-args)) #t))

(define (fresh-tmp prefix)
  (set! tmp-count (add1 tmp-count))
  (define directory (build-path (tmp-root) (format "~a-~a" prefix (~r tmp-count #:min-width 6 #:pad-string "0"))))
  (make-directory directory)
  (path->string directory))

(define (tmp-args directory)
  (for/list ([argument (in-list (fixture-args))])
    (if (equal? argument tmp-token) directory argument)))

(define fixture-directory
  (path->string (path->directory-path (simplify-path (build-path tests-directory "fixtures")))))

(define (unfixture result)
  (match-define (list status stdout stderr) result)
  (list status (string-replace stdout fixture-directory fixture-token) (string-replace stderr fixture-directory fixture-token)))

(define (untmp directory result)
  (list (first result)
        (string-replace (second result) directory tmp-token)
        (string-replace (third result) directory tmp-token)))

(define (run-process program #:input [input #""] #:timeout [timeout #f] . arguments)
  (define-values (process out in err) (apply subprocess #f #f #f program arguments))
  (define writer
    (thread (lambda ()
              (with-handlers ([exn:fail? void]) (write-bytes input in))
              (with-handlers ([exn:fail? void]) (close-output-port in)))))
  (define stderr #f)
  (define stdout #f)
  (define readers
    (list (thread (lambda () (set! stderr (port->string err))))
          (thread (lambda () (set! stdout (port->string out))))))
  (define finished (sync/timeout timeout process))
  (unless finished (subprocess-kill process #t))
  (for-each thread-wait readers)
  (thread-wait writer)
  (close-input-port out)
  (close-input-port err)
  (subprocess-wait process)
  (list (if finished (subprocess-status process) 'timeout) stdout stderr))

(define (process-exited? pid)
  (define stat (build-path "/proc" pid "stat"))
  (define state
    (with-handlers ([exn:fail:filesystem? (lambda (e) #f)])
      (regexp-match #rx"^.*[)] (.)" (file->string stat))))
  (or (not state) (equal? (cadr state) "Z")))

(define (process-gone? pid)
  (define deadline (+ (current-inexact-milliseconds) 5000))
  (let wait ()
    (cond
      [(process-exited? pid) #t]
      [(> (current-inexact-milliseconds) deadline) #f]
      [else (sleep 0.02) (wait)])))

(define (run-vm-process #:timeout timeout . arguments)
  (when (and (fixture-channel) (not python))
    (error 'vm-diff "the child channel needs Python 3"))
  (if (fixture-channel)
      (apply run-process python #:input (fixture-input) #:timeout timeout
             (path->string channel-run-file) (path->string (fixture-channel)) (path->string vm-file) arguments)
      (apply run-process vm-file #:input (fixture-input) #:timeout timeout arguments)))

(define (channel-words)
  (if (fixture-channel)
      (string-append (string-join (map shell-quote (list (path->string python) (path->string channel-run-file)
                                                         (path->string (fixture-channel)))))
                     " ")
      ""))

(define (run-vm bytecode limit #:style [style 'json] #:timeout [timeout #f] #:root [root '()] . extra)
  (apply run-vm-process #:timeout timeout
         (append (allow-options)
                 (limit-options limit)
                 (style-options style)
                 root
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

(define (limit-options limit)
  (if limit (list "--max-steps" (number->string limit)) '()))

(define (allow-options)
  (if (fixture-allow-run) '("--allow-run") '()))

; The fixtures are run as the CLI runs a program in tests/fixtures/vm: the stored names are put under that folder,
; and unfixture turns it into @fixtures/ in the output.
(define (source-root-options)
  (list "--source-root"
        (path->string (simplify-path (build-path tests-directory "fixtures" "vm")))))

(define (vm-batch name bytecode directory option-lists)
  (define process #f)
  (define out #f)
  (define err #f)
  (define tmps
    (for/list ([_options (in-list option-lists)])
      (and (uses-tmp?) (fresh-tmp "vm"))))
  (dynamic-wind
    void
    (lambda ()
      (make-directory* directory)
      (define input (build-path directory "stdin"))
      (call-with-output-file input (lambda (port) (void (write-bytes (fixture-input) port))))
      (define (tail tmp)
        (string-join (map shell-quote (append (list "--" (path->string bytecode))
                                              (if tmp (tmp-args tmp) (fixture-args))))))
      (define script (build-path directory "run.sh"))
      (call-with-output-file script
        (lambda (port)
          (write-string "exec 2>/dev/null\nhung=0\n" port)
          (for ([options (in-list option-lists)] [tmp (in-list tmps)] [index (in-naturals)])
            (define base (path->string (build-path directory (number->string index))))
            (define out-file (shell-quote (string-append base ".out")))
            (define err-file (shell-quote (string-append base ".err")))
            (write-string
             (format (string-append "if [ $hung = 0 ]; then\n  ~a~a~a ~a ~a < ~a > ~a 2> ~a\n  status=$?\n"
                                    "else\n  : > ~a\n  : > ~a\n  status=124\nfi\n"
                                    "echo $status > ~a\ncase $status in 124|137) hung=1 ;; esac\n")
                     (channel-words)
                     (if timeout-program
                         (format "~a --foreground -k 5 ~a "
                                 (shell-quote (path->string timeout-program)) run-timeout)
                         "")
                     (shell-quote (path->string vm-file)) (string-join (map shell-quote (append (allow-options) (source-root-options) options)))
                     (tail tmp)
                     (shell-quote (path->string input)) out-file err-file out-file err-file
                     (shell-quote (string-append base ".status")))
             port))))
      (define-values (started stdout-port stdin-port stderr-port)
        (parameterize ([subprocess-group-enabled #t])
          (subprocess #f #f #f (or (find-executable-path "sh") "/bin/sh") (path->string script))))
      (set! process started)
      (set! out stdout-port)
      (set! err stderr-port)
      (close-output-port stdin-port)
      (define stdout (port->string out))
      (define stderr (port->string err))
      (subprocess-wait process)
      (unless (and (zero? (subprocess-status process)) (equal? stdout "") (equal? stderr ""))
        (error 'vm-diff "~a: VM batch failed: ~a ~a" name stdout stderr))
      (for/list ([index (in-range (length option-lists))] [tmp (in-list tmps)])
        (define (part extension) (build-path directory (format "~a~a" index extension)))
        (define result
          (list (string->number (string-trim (file->string (part ".status"))))
                (file->string (part ".out"))
                (file->string (part ".err"))))
        (unfixture (if tmp (untmp tmp result) result))))
    (lambda ()
      (when process
        (when (eq? (subprocess-status process) 'running) (subprocess-kill process #t))
        (subprocess-wait process))
      (when out (close-input-port out))
      (when err (close-input-port err))
      (for ([tmp (in-list tmps)] #:when tmp)
        (delete-directory/files tmp #:must-exist? #f))
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

(define fixture-filter
  (let* ([text (getenv "AGENTICA_FIXTURES")]
         [names (and text (string-split text #px"[\\s,]+"))])
    (and (pair? names)
         (begin
           (when (getenv "CI")
             (error 'vm-diff "AGENTICA_FIXTURES must not be set when CI is set: CI runs every fixture"))
           names))))

(define (fixture-selected? name)
  (or (not fixture-filter) (and (member name fixture-filter) #t)))

(define (program-name program)
  (path->string (path-replace-extension (file-name-from-path program) #"")))

(define (select-programs programs)
  (for/list ([program (in-list programs)] #:when (fixture-selected? (program-name program)))
    program))

(define (check-fixture-filter)
  (when fixture-filter
    (define known (map program-name (append (fixture-programs) (runaway-programs))))
    (define unknown (filter (lambda (name) (not (member name known))) fixture-filter))
    (when (pair? unknown)
      (eprintf "vm-diff: no fixture named ~a in tests/fixtures/vm (names go without .agc)\n" (string-join unknown ", "))
      (exit 2))))

(define (runaway-programs)
  (sort (for/list ([file (in-list (directory-list (build-path fixtures "step-limited") #:build? #t))]
                   #:when (path-has-extension? file #".agc"))
          file)
        path<?))

(define (last-line-start text)
  (let search ([index (string-length text)])
    (cond
      [(zero? index) 0]
      [(char=? (string-ref text (sub1 index)) #\newline) index]
      [else (search (sub1 index))])))

(define (outcome result)
  (define stderr (third result))
  (define body (if (string-suffix? stderr "\n") (substring stderr 0 (sub1 (string-length stderr))) stderr))
  (define start (last-line-start body))
  (define parsed
    (and (equal? (first result) 1)
         (with-handlers ([exn:fail? (lambda (_) #f)]) (string->jsexpr (substring body start)))))
  (define code (and (hash? parsed) (not (hash-ref parsed 'task #f)) (string? (hash-ref parsed 'code #f))
                    (hash-ref parsed 'code)))
  (list (first result) (second result) (if code (substring stderr 0 start) stderr) code))

(define (text-code stderr)
  (define found
    (regexp-match* #px"(?m:error\\[([A-Z]+-[A-Z0-9-]+)\\]$|^\\[([A-Z]+-[A-Z0-9-]+)\\]$)" stderr #:match-select cdr))
  (and (pair? found) (ormap values (last found))))

(define (diagnostic-code result)
  (fourth (outcome result)))

(define (step-limited? result)
  (equal? (diagnostic-code result) "RUNTIME-STEP-LIMIT"))

(define (check-limited on-vm full name limit #:note [note ""])
  (define seen (outcome on-vm))
  (define message (format "~a --max-steps ~a~a (exit 124/137 or timeout: the run timed out): ~s" name limit note seen))
  (unless (equal? seen full)
    (check-equal? (first seen) 1 message)
    (check-equal? (fourth seen) "RUNTIME-STEP-LIMIT" message)
    (check-true (string-prefix? (second full) (second seen)) message)
    (check-true (string-prefix? (third full) (third seen)) message))
  (equal? seen full))

(define (check-sweep results limits full name #:note [note ""])
  (define finished
    (for/fold ([finished #f]) ([on-vm (in-list results)] [limit (in-list limits)])
      (define done (check-limited on-vm full name limit #:note note))
      (when finished
        (check-true done (format "~a --max-steps ~a~a stops after a smaller limit finished" name limit note)))
      done))
  (check-true finished (format "~a finishes under --max-steps ~a~a" name (last limits) note)))

(define (run-fixture-vm bytecode limit)
  (unfixture (run-fixture-vm-raw bytecode limit)))

(define (run-fixture-vm-raw bytecode limit)
  (cond
    [(uses-tmp?)
     (define directory (fresh-tmp "vm"))
     (dynamic-wind
       void
       (lambda ()
         (untmp directory (apply run-vm-process #:timeout run-timeout
                                 (append (allow-options) (limit-options limit) (style-options 'json) (source-root-options)
                                         (list "--" (path->string bytecode)) (tmp-args directory)))))
       (lambda () (delete-directory/files directory #:must-exist? #f)))]
    [else (run-vm bytecode limit #:timeout run-timeout #:root (source-root-options))]))

(define (total-steps bytecode)
  (define (limited? limit) (step-limited? (run-fixture-vm bytecode limit)))
  (let search ([low 1] [high 1])
    (cond
      [(limited? high) (search high (* 2 high))]
      [(>= low high) high]
      [else
       (let narrow ([low low] [high high])
         (define middle (quotient (+ low high) 2))
         (cond
           [(>= low high) high]
           [(limited? middle) (narrow (add1 middle) high)]
           [else (narrow low middle)]))])))

(define (last-limit steps)
  (max (+ (* 2 steps) 100) (+ steps (* 2 vm-turn-steps))))

(define (step-allowance steps)
  (+ steps (max 10 (quotient steps 10))))

(define (sweep-limits total expected-steps)
  (append
   (if (<= total full-sweep-limit)
       (range 1 (add1 total))
       (remove-duplicates
        (append (range 1 (add1 sweep-head))
                (range sweep-head total (quotient total 50))
                (list (sub1 total) total))))
   (list (last-limit expected-steps))))

(define (head-sha)
  (define git (find-executable-path "git"))
  (and git
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (parameterize ([current-directory root] [current-error-port (open-output-nowhere)])
           (string-trim (with-output-to-string (lambda () (system* git "rev-parse" "HEAD"))))))))

(define sweep-seed
  (let ([given (getenv "AGENTICA_SWEEP_SEED")])
    (cond
      [given
       (define n (string->number given))
       (unless (exact-nonnegative-integer? n)
         (error 'vm-diff "AGENTICA_SWEEP_SEED must be a natural number, not ~s" given))
       n]
      [sampled-sweep?
       (define sha (or (getenv "GITHUB_SHA") (head-sha)))
       (if (and sha (regexp-match? #px"^[0-9a-f]{8}" sha)) (string->number (substring sha 0 8) 16) 0)]
      [else 0])))

(define (sweep-note)
  (if sampled-sweep? (format " [sampled sweep: AGENTICA_SWEEP=sampled AGENTICA_SWEEP_SEED=~a]" sweep-seed) ""))

(define (name-seed name)
  (for/fold ([hash 0]) ([byte (in-bytes (string->bytes/utf-8 name))])
    (modulo (+ (* hash 31) byte) 2147483647)))

(define (sampled-limits total expected-steps name)
  (define low 3)
  (define high (- total 2))
  (define span (add1 (- high low)))
  (define middle
    (if (<= span sample-points)
        (range low (add1 high))
        (parameterize ([current-pseudo-random-generator (make-pseudo-random-generator)])
          (random-seed (add1 (modulo (+ sweep-seed (name-seed name)) 2147483646)))
          (for/list ([bucket (in-range sample-points)])
            (define from (+ low (quotient (* bucket span) sample-points)))
            (define to (+ low (quotient (* (add1 bucket) span) sample-points)))
            (+ from (random (- to from)))))))
  (append (sort (remove-duplicates (filter (lambda (limit) (<= 1 limit total))
                                           (append (list 1 2) middle (list (sub1 total) total))))
                <)
          (list (last-limit expected-steps))))

(define (expected-file program)
  (path-replace-extension program #".expected"))

(define (lines-of text)
  (if (equal? text "") '() (regexp-split #rx"\n" text)))

(define (json-lines name text)
  (define items (lines-of text))
  (if (null? items)
      (format "  ~a: []" (jsexpr->string name))
      (string-append "  " (jsexpr->string name) ": [\n"
                     (string-join (for/list ([item (in-list items)]) (string-append "    " (jsexpr->string item)))
                                  ",\n")
                     "\n  ]")))

(define (expected->string result [steps #f])
  (match-define (list status stdout stderr code) result)
  (string-append "{\n  \"exit\": " (number->string status) ",\n  \"code\": " (jsexpr->string (or code 'null)) ",\n"
                 (if steps (format "  \"steps\": ~a,\n" steps) "")
                 (json-lines "stdout" stdout) ",\n" (json-lines "stderr" stderr) "\n}\n"))

(define (read-golden program)
  (define file (expected-file program))
  (unless (file-exists? file)
    (error 'vm-golden "~a is missing; run make goldens" file))
  (call-with-input-file file read-json))

(define (read-expected program)
  (define data (read-golden program))
  (define (text key) (string-join (hash-ref data key) "\n"))
  (define code (hash-ref data 'code))
  (list (hash-ref data 'exit) (text 'stdout) (text 'stderr) (and (string? code) code)))

(define (read-expected-steps program)
  (define steps (hash-ref (read-golden program) 'steps #f))
  (unless (exact-positive-integer? steps)
    (error 'vm-golden "~a has no step count; run make goldens" (expected-file program)))
  steps)

(define (check-steps total expected-steps name)
  (check-true (<= total (step-allowance expected-steps))
              (format "~a takes ~a steps, more than its golden ~a allows (over-charging)" name total expected-steps)))

(define (fixture-name program)
  (path->string (file-name-from-path program)))

(define (fixture-environment file)
  (define env (environment-variables-copy (current-environment-variables)))
  (for ([entry (in-list (file->value file))])
    (environment-variables-set! env (string->bytes/utf-8 (car entry)) (string->bytes/utf-8 (cdr entry))))
  env)

(define (call-with-fixture program thunk)
  (define (sidecar extension read-it default)
    (define file (path-replace-extension program extension))
    (if (file-exists? file) (read-it file) default))
  (parameterize ([fixture-input (sidecar #".stdin" file->bytes #"")]
                 [fixture-args (sidecar #".args" (lambda (file) (map fixture-arg (file->value file))) '())]
                 [current-environment-variables (sidecar #".env" fixture-environment (current-environment-variables))]
                 [fixture-channel (sidecar #".channel" values #f)]
                 [fixture-allow-run (string-prefix? (fixture-name program) allow-run-prefix)])
    (thunk)))

(define (fixture-bytecode work program)
  (define bytecode (build-path work (path-replace-extension (file-name-from-path program) #".agcb")))
  (compile-file program bytecode)
  bytecode)

(define (python-ready? name)
  (cond
    [python #t]
    [(getenv "CI") (error 'vm-diff "~a needs Python 3 for its child channel in CI" name)]
    [else (printf "SKIP ~a: python3 is unavailable\n" name) #f]))

(define (channel-ready? name)
  (or (not (fixture-channel)) (python-ready? name)))

(define (run-fixture work program)
  (define name (fixture-name program))
  (define bytecode (fixture-bytecode work program))
  (define runs (build-path work (format "~a-runs" name)))
  (call-with-fixture
   program
   (lambda ()
     (when (channel-ready? name)
       (test-case (format "~a gives its expected exit code, stdout, stderr and diagnostic code under every --max-steps" name)
         (define full (read-expected program))
         (define expected-steps (read-expected-steps program))
         (define total (total-steps bytecode))
         (check-steps total expected-steps name)
         (define limits (if sampled-sweep? (sampled-limits total expected-steps name) (sweep-limits total expected-steps)))
         (define text-styles '(plain ai))
         (define vm-results
           (vm-batch name bytecode runs
                     (append (list (style-options 'json))
                             (map style-options text-styles)
                             (for/list ([limit (in-list limits)])
                               (append (limit-options limit) (style-options 'json))))))
         (check-equal? (outcome (first vm-results)) full name)
         (for ([style (in-list text-styles)] [on-vm (in-list (rest vm-results))])
           (check-text-format on-vm full (format "~a ~a" name style)))
         (check-sweep (list-tail vm-results (add1 (length text-styles))) limits full name #:note (sweep-note)))))))

(define (json-crash-free text)
  (for/fold ([kept '()] [codes '()] [summaries '()]
             #:result (values (string-join (reverse kept) "\n") (reverse codes) (reverse summaries)))
            ([line (in-list (regexp-split #rx"\n" text))])
    (define parsed (with-handlers ([exn:fail? (lambda (_) #f)]) (string->jsexpr line)))
    (cond
      [(and (hash? parsed) (eq? (hash-ref parsed 'task #f) #t))
       (values kept (cons (hash-ref parsed 'code) codes) summaries)]
      [(and (hash? parsed) (hash-has-key? parsed 'unobserved_crashes))
       (values kept codes (cons (list (hash-ref parsed 'unobserved_crashes) (hash-ref parsed 'first)) summaries))]
      [else (values (cons line kept) codes summaries)])))

(define stack-line-patterns
  (list #px"^    \\S+ at .+:[0-9]+:[0-9]+(?: \\([0-9]+ times\\))?(?: \\(after a tail call\\))?$"
        #px"^    \\.\\.\\. [0-9]+ frames? not shown \\.\\.\\.$"
        #px"^    task spawned at .+:[0-9]+:[0-9]+$"))

(define (skip-stack lines header)
  (if (and (pair? lines) (equal? (car lines) header))
      (let skip ([rest (cdr lines)])
        (if (and (pair? rest) (ormap (lambda (pattern) (regexp-match? pattern (car rest))) stack-line-patterns))
            (skip (cdr rest))
            rest))
      lines))

(define (text-crash-free text)
  (define plain-header #px"^.*:[0-9]+:[0-9]+ error\\[([A-Z]+-[A-Z0-9-]+)\\] in a task$")
  (define ai-header #px"^\\[([A-Z]+-[A-Z0-9-]+)\\] in a task$")
  (define summary #px"^([0-9]+) task crash(?:es were| was) not observed; first: (.*)$")
  (define (after-caret lines)
    (define rest (memf (lambda (line) (regexp-match? #px"^ +\\| [ \t]*\\^+$" line)) lines))
    (if rest (skip-stack (cdr rest) "  = stack, innermost first:") '()))
  (let loop ([lines (regexp-split #rx"\n" text)] [kept '()] [codes '()] [summaries '()])
    (cond
      [(null? lines) (values (string-join (reverse kept) "\n") (reverse codes) (reverse summaries))]
      [(and (>= (length lines) 4) (regexp-match ai-header (first lines)))
       => (lambda (found) (loop (skip-stack (drop lines 4) "  stack:") kept (cons (cadr found) codes) summaries))]
      [(regexp-match plain-header (car lines))
       => (lambda (found) (loop (after-caret (cdr lines)) kept (cons (cadr found) codes) summaries))]
      [(regexp-match summary (car lines))
       => (lambda (found)
            (loop (cdr lines) kept codes (cons (list (string->number (cadr found)) (caddr found)) summaries)))]
      [else (loop (cdr lines) (cons (car lines) kept) codes summaries)])))

(define (check-text-format on-vm full message)
  (check-equal? (take on-vm 2) (take full 2) message)
  (define-values (stderr text-crashes text-summaries) (text-crash-free (third on-vm)))
  (define-values (expected json-crashes json-summaries) (json-crash-free (third full)))
  (check-equal? text-crashes json-crashes message)
  (check-equal? text-summaries json-summaries message)
  (check-true (string-prefix? stderr expected) message)
  (define diagnostic (substring stderr (min (string-length stderr) (string-length expected))))
  (if (fourth full)
      (check-equal? (text-code diagnostic) (fourth full) message)
      (check-equal? diagnostic "" message)))

(define (run-shard shard)
  (when sampled-sweep?
    (printf "vm-diff shard ~a: sampled --max-steps sweep, AGENTICA_SWEEP_SEED=~a\n" shard sweep-seed))
  (when (vm-built?)
    (define work (make-temporary-directory "agentica-vm~a"))
    (define assignment (shard-assignment (fixture-programs)))
    (dynamic-wind
      void
      (lambda ()
        (parameterize ([tmp-root work])
          (for ([entry (in-list assignment)] #:when (= (cdr entry) shard))
            (run-fixture work (car entry))))
        (when (= shard extras-shard)
          (run-extras work assignment)))
      (lambda () (delete-directory/files work)))))

(define (check-runaway work program)
  (define name (fixture-name program))
  (define bytecode (fixture-bytecode work program))
  (define expected (read-expected program))
  (for ([limit (in-list (append '(1 2 3 4 5 50) (list runaway-limit)))])
    (define message (format "~a --max-steps ~a" name limit))
    (define on-vm (run-vm bytecode limit #:timeout run-timeout))
    (check-equal? (first on-vm) 1 message)
    (check-true (step-limited? on-vm) message)
    (check-false (string-contains? (second on-vm) "done") message)
    (check-true (string-prefix? (second expected) (second on-vm)) message)
    (check-true (string-prefix? (third expected) (third (outcome on-vm))) message)
    (when (= limit runaway-limit)
      (check-equal? (outcome on-vm) expected message))))

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
  (test-case "the VM reads piped stdin like the file redirect"
    (for ([name (in-list '("io-read" "io-rest"))])
      (define program (build-path fixtures (string-append name ".agc")))
      (define bytecode (build-path work (string-append name "-pipe.agcb")))
      (compile-file program bytecode)
      (parameterize ([fixture-input (file->bytes (build-path fixtures (string-append name ".stdin")))])
        (check-equal? (outcome (run-vm bytecode #f)) (read-expected program) name))))
  (test-case "runaway loops stop at --max-steps with a prefix of their expected output"
    (for ([program (in-list (runaway-programs))])
      (check-runaway work program)))
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
    (define draws (build-path work "random-draws.agc"))
    (display-to-file "def main() -> Void\n  puts(Random.int(0, 1000000000))\n  puts(Random.float)\nend\n" draws #:exists 'replace)
    (define draws-bytecode (build-path work "random-draws.agcb"))
    (compile-file draws draws-bytecode)
    (define (seeded seed) (run-process vm-file "--seed" seed "--" (path->string draws-bytecode)))
    (check-equal? (first (seeded "0002147483647")) 0)
    (check-equal? (seeded "7") (seeded "7"))
    (check-not-equal? (second (seeded "7")) (second (seeded "8")))
    (when (python-ready? "seeded Test.run draws")
      (define tests (build-path work "seeded-tests.agc"))
      (display-to-file (string-append "def main() -> Void\n  Test.run([\n"
                                      "    Test.test(\"a\") do\n      puts(Random.int(0, 1000000000))\n      ok()\n    end,\n"
                                      "    Test.test(\"b\") do\n      puts(Random.int(0, 1000000000))\n      ok()\n    end\n"
                                      "  ])\nend\n")
                       tests #:exists 'replace)
      (define tests-bytecode (build-path work "seeded-tests.agcb"))
      (compile-file tests tests-bytecode)
      (define (test-draws seed order)
        (define feed (build-path work (format "seeded-~a.channel" (equal-hash-code order))))
        (display-to-file order feed #:exists 'replace)
        (define run
          (parameterize ([fixture-channel feed])
            (run-vm-process #:timeout run-timeout "--seed" seed "--" (path->string tests-bytecode) "--agentica-test" "run")))
        (check-equal? (first run) 0 (third run))
        (filter (lambda (line) (not (string-prefix? line "channel> "))) (string-split (second run) "\n")))
      (define alone (test-draws "7" #"1\n"))
      (define mixed (test-draws "7" #"0\n1\n1\n"))
      (check-equal? (list (second mixed) (third mixed)) (list (first alone) (first alone)))
      (check-not-equal? (first mixed) (second mixed))
      (check-not-equal? (test-draws "8" #"1\n") alone))
    (define duplicate (build-path work "test-name-duplicate.agcb"))
    (compile-file (build-path fixtures "test-name-duplicate.agc") duplicate)
    (define named (run-process vm-file "--json" "--" (path->string duplicate) "--agentica-test" "run"))
    (define start (hash-ref (hash-ref (string->jsexpr (third named)) 'range) 'start))
    (check-equal? (list (first named) (hash-ref start 'line) (hash-ref start 'column)) '(1 9 5))
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
    (test-case "agentica runs programs on the VM with their expected exit code, stdout and diagnostic code"
      (define temp (make-temporary-directory "agentica-cli~a"))
      (define (expected name) (read-expected (build-path fixtures name)))
      (define (fixture name) (path->string (build-path fixtures name)))
      (define (no-bytecode arguments)
        (check-equal? (bytecode-files temp) '() (format "~a leaves no bytecode" arguments)))
      (dynamic-wind
        void
        (lambda ()
          (for* ([name (in-list '("calls.agc" "division-by-zero.agc" "linked.agc"))]
                 [style (in-list '(plain ai json))])
            (define arguments (append (style-options style) (list (fixture name))))
            (define result (apply run-cli temp arguments))
            (if (eq? style 'json)
                (check-equal? (outcome result) (expected name) (format "~a" arguments))
                (check-text-format result (expected name) (format "~a" arguments)))
            (no-bytecode arguments)
            (when (equal? name "linked.agc") (check-equal? (first result) 1)))
          (define calls (fixture "calls.agc"))
          (define (limited . arguments)
            (define result (apply run-cli temp "--json" "--max-steps" "3" arguments))
            (list (first result) (fourth (outcome result))))
          (check-equal? (limited calls) (list 1 "RUNTIME-STEP-LIMIT"))
          (check-equal? (bytecode-files temp) '())
          (define with-args (run-cli temp "--json" calls "first" "--allow-run" "--json"))
          (check-equal? (take with-args 2) (take (expected "calls.agc") 2))
          (define deep (build-path temp "deep.agc"))
          (display-to-file
           (string-append
            "def loop(n: Int, acc: Int) -> Int\n  if n == 0\n    return acc\n  end\n  return loop(n - 1, acc + 1)\nend\n\n"
            "def main() -> Void\n  puts(loop(100000, 0))\nend\n")
           deep)
          (check-equal? (run-cli temp (path->string deep)) (list 0 "100000\n" ""))
          (for ([removed (in-list '("--vm" "--legacy-eval"))])
            (check-equal? (take (run-cli temp removed (path->string deep)) 2) (list 1 "") removed))
          (delete-file deep)
          (define denied (fixture "spawn-denied.agc"))
          (check-equal? (outcome (run-cli temp "--json" denied)) (expected "spawn-denied.agc"))
          (check-equal? (first (run-cli temp "--allow-run" "--json" denied)) 0)
          (define random (fixture "random.agc"))
          (define seeded (run-cli temp "--seed" "77" random))
          (check-equal? (first seeded) 0)
          (check-equal? (run-cli temp "--seed" "77" random) seeded)
          (check-equal? (first (run-cli temp "--seed" "2147483648" random)) 2)
          (check-equal? (first (run-cli temp "--max-steps" "0" calls)) 2)
          (define missing (run-cli temp #:vm (build-path temp "no-vm") calls))
          (check-equal? (first missing) 2)
          (check-true (string-prefix? (third missing) "agentica: cannot find the VM at "))
          (define plain (build-path temp "plain-vm"))
          (copy-file vm-file plain)
          (file-or-directory-permissions plain #o644)
          (check-equal? (first (run-cli temp #:vm plain calls)) 2)
          (delete-file plain)
          (check-equal? (outcome (run-cli-in-process temp "--json" calls)) (expected "calls.agc"))
          (define gets (fixture "io-gets.agc"))
          (define input (file->bytes (build-path fixtures "io-gets.stdin")))
          (check-equal? (outcome (run-cli temp #:input input "--json" gets)) (expected "io-gets.agc"))
          (check-equal? (outcome (run-cli-in-process temp #:input input "--json" gets)) (expected "io-gets.agc"))
          (define broken
            (make-input-port 'broken (lambda (_) (raise (exn:fail "read failed" (current-continuation-marks))))
                             #f void))
          (define failed (run-cli-in-process temp #:port broken "--json" gets))
          (check-equal? (first failed) 1)
          (check-equal? (hash-ref (string->jsexpr (last (string-split (third failed) "\n"))) 'code)
                        "RUNTIME-INTERNAL")
          (check-equal? (first (run-cli temp (fixture "system-exit.agc"))) 3)
          (check-equal? (run-cli temp "--json" (fixture "system-args.agc") "a" "" "λ 𝔸" "--json" "--vm")
                        (list 0 "0 \"a\"\n1 \"\"\n2 \"λ 𝔸\"\n3 \"--json\"\n4 \"--vm\"\n[\"a\", \"\", \"λ 𝔸\", \"--json\", \"--vm\"]\n" ""))
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
    (test-case "a read stuck on a FIFO times out, closes the handle and does not hold the VM at exit"
      (define program (build-path work "fifo-stuck.agc"))
      (display-to-file
       (string-append
        "def main() -> Void\n  input = Result.unwrap!(File.open(System.args()[0], \"read\", 60000))\n"
        "  IO.inspect(File.read_bytes(input, 4, 300))\n  IO.inspect(File.read_line(input, 300))\n"
        "  IO.inspect(File.close(input, 300))\n  puts(\"done\")\nend\n")
       program)
      (define bytecode (build-path work "fifo-stuck.agcb"))
      (compile-file program bytecode)
      (define fifo (build-path work "stuck-fifo"))
      (check-true (system* (find-executable-path "mkfifo") (path->string fifo)))
      (define-values (held-in held-out) (open-input-output-file fifo #:exists 'update))
      (define (release)
        (close-input-port held-in)
        (close-output-port held-out))
      (define watchdog (thread (lambda () (sleep 30) (release))))
      (dynamic-wind
        void
        (lambda ()
          (parameterize ([fixture-args (list (path->string fifo))])
            (define expected
              (list 0 "error(\"filesystem: operation timed out\")\nerror(\"filesystem: file handle is closed\")\nok()\ndone\n" ""))
            (define start (current-inexact-milliseconds))
            (check-equal? (run-vm bytecode #f) expected)
            (check-true (< (- (current-inexact-milliseconds) start) 20000))))
        (lambda ()
          (kill-thread watchdog)
          (release)
          (delete-file fifo))))

    (test-case "Process.spawn searches PATH only and resolves a name with / against the working directory"
      (define program (build-path work "path-lookup.agc"))
      (display-to-file
       (string-append
        "def show(name: String) -> Void\n  case Process.spawn(name, [\"x\"], 60000)\n"
        "    ok(p) ->\n      puts(\"#{name}: #{Process.read_line(p, 60000)} #{Process.wait(p, 60000)}\")\n"
        "      Process.close(p)\n    error(message) -> puts(\"#{name}: #{message}\")\n  end\nend\n\n"
        "def main() -> Void\n  show(\"agc-tool\")\n  show(\"./agc-tool\")\n  show(\"bin/agc-tool\")\n  show(\"bin\")\nend\n")
       program)
      (define bytecode (build-path work "path-lookup.agcb"))
      (compile-file program bytecode)
      (define folder (build-path work "lookup"))
      (make-directory* (build-path folder "bin"))
      (for ([file (list (build-path folder "agc-tool") (build-path folder "bin" "agc-tool"))])
        (display-to-file "#!/bin/sh\necho \"ran $1\"\n" file)
        (file-or-directory-permissions file #o755))
      (define (expected found)
        (list 0
              (string-append "agc-tool: " (if found "ok(\"ran x\") ok(0)" "process: executable is unavailable")
                             "\n./agc-tool: ok(\"ran x\") ok(0)\nbin/agc-tool: ok(\"ran x\") ok(0)\n"
                             "bin: process: executable is unavailable\n")
              ""))
      (define none (path->string (build-path folder "none")))
      (for ([search (list none (string-append ":" none) (string-append "bin:" none) (string-append ".:" none))])
        (define env (environment-variables-copy (current-environment-variables)))
        (environment-variables-set! env #"PATH" (string->bytes/utf-8 search))
        (parameterize ([current-directory folder]
                       [current-environment-variables env]
                       [fixture-allow-run #t])
          (define want (expected (or (string-prefix? search "bin:") (string-prefix? search ".:"))))
          (check-equal? (run-vm bytecode #f #:timeout run-timeout) want search)))
      (delete-directory/files folder))

    (test-case "agentica stopped by SIGTERM kills the VM's running children"
      (define program (build-path work "signal-children.agc"))
      (display-to-file
       (string-append
        "def main() -> Void\n  p = Result.unwrap!(Process.spawn(\"/bin/sh\", [\"-c\", \"echo $$; exec sleep 30\"], 60000))\n"
        "  puts(Result.unwrap!(Process.read_line(p, 60000)))\n  IO.flush()\n  Task.sleep(20000)\nend\n")
       program)
      (define-values (driver out in err)
        (parameterize ([current-environment-variables (cli-environment work vm-file)])
          (subprocess #f #f #f (find-system-path 'exec-file) (path->string main-file)
                      "--allow-run" (path->string program))))
      (define pid #f)
      (dynamic-wind
        void
        (lambda ()
          (close-output-port in)
          (set! pid (sync/timeout run-timeout (read-line-evt out)))
          (check-pred string? pid)
          (when (string? pid)
            (check-true (directory-exists? (build-path "/proc" pid)))
            (unix-kill (subprocess-pid driver) sigterm)
            (check-not-false (sync/timeout run-timeout driver))
            (check-true (process-gone? pid) pid)))
        (lambda ()
          (subprocess-kill driver #t)
          (when (and (string? pid) (directory-exists? (build-path "/proc" pid)))
            (unix-kill (string->number pid) sigkill))
          (close-input-port out)
          (close-input-port err))))

    (test-case "closing a captured VM child sends SIGTERM first, so the child stops its own children"
      (define inner (build-path work "captured-inner.agc"))
      (display-to-file
       (string-append
        "def main() -> Void\n"
        "  p = Result.unwrap!(Process.spawn(\"/bin/sh\", [\"-c\", \"echo $PPID $$; exec sleep 30\"], 60000))\n"
        "  puts(Result.unwrap!(Process.read_line(p, 60000)))\n  IO.flush()\n  Task.sleep(5000)\nend\n")
       inner)
      (define outer (build-path work "captured-outer.agc"))
      (display-to-file
       (string-append
        "def main() -> Void\n  args = System.args()\n"
        "  child = Result.unwrap!(Process.spawn_captured(args[0], [\"--allow-run\", \"--\", args[1]], \".\", 60000))\n"
        "  puts(Result.unwrap!(Process.read_line(child, 60000)))\n"
        "  if args[2] == \"close\"\n    Process.close(child)\n  else\n    IO.inspect(Process.read_line(child, 200))\n  end\nend\n")
       outer)
      (define inner-code (build-path work "captured-inner.agcb"))
      (define outer-code (build-path work "captured-outer.agcb"))
      (compile-file inner inner-code)
      (compile-file outer outer-code)
      (for ([mode (in-list '("close" "timeout"))])
        (define pids '())
        (dynamic-wind
          void
          (lambda ()
            (define result
              (parameterize ([fixture-allow-run #t])
                (run-vm outer-code #f #:timeout run-timeout (path->string vm-file) (path->string inner-code) mode)))
            (define lines (string-split (second result) "\n"))
            (set! pids (if (pair? lines) (filter (lambda (word) (string->number word)) (string-split (first lines))) '()))
            (check-equal? (first result) 0 mode)
            (check-equal? (rest lines) (if (equal? mode "close") '() '("error(\"network: operation timed out\")")) mode)
            (check-equal? (length pids) 2 mode)
            (for ([pid (in-list pids)])
              (check-true (process-gone? pid) (format "~a: ~a" mode pid))))
          (lambda ()
            (for ([pid (in-list pids)] #:when (directory-exists? (build-path "/proc" pid)))
              (unix-kill (string->number pid) sigkill))))))

    (test-case "close never waits for a captured child; one that ignores SIGTERM gets SIGKILL a second later"
      (define program (build-path work "captured-grace.agc"))
      (display-to-file
       (string-append
        "def main() -> Void\n  mode = System.args()[0]\n"
        "  script = \"trap '' TERM; echo $$; exec sleep 30\"\n"
        "  if mode == \"quick\"\n    script = \"echo $$; exec sleep 30\"\n  end\n"
        "  p = Result.unwrap!(Process.spawn_captured(\"/bin/sh\", [\"-c\", script], \".\", 60000))\n"
        "  pid = Result.unwrap!(Process.read_line(p, 60000))\n  puts(pid)\n  IO.flush()\n"
        "  start = Time.monotonic_ms()\n  Process.close(p)\n  puts(Time.monotonic_ms() - start)\n"
        "  if mode == \"wait\"\n    Task.sleep(1500)\n"
        "    puts(Result.ok?(File.stat(\"/proc/#{pid}\", 60000)))\n  end\nend\n")
       program)
      (define bytecode (build-path work "captured-grace.agcb"))
      (compile-file program bytecode)
      (define traced? (not (regexp-match? #rx"trace off" (second (run-process vm-file "--version")))))
      (define env (environment-variables-copy (current-environment-variables)))
      (environment-variables-set! env #"AGENTICA_VM_TRACE" #"io")
      (for ([mode (in-list '("wait" "exit" "quick"))])
        (define pid #f)
        (dynamic-wind
          void
          (lambda ()
            (define result
              (parameterize ([fixture-allow-run #t] [current-environment-variables env])
                (run-vm bytecode #f #:timeout run-timeout mode)))
            (define lines (string-split (second result) "\n"))
            (set! pid (and (pair? lines) (string->number (first lines)) (first lines)))
            (check-equal? (first result) 0 mode)
            (check-pred string? pid mode)
            (check-true (and (>= (length lines) 2) (< (string->number (second lines)) 500)) (format "~a: ~a" mode lines))
            (check-equal? (list-tail lines (min 2 (length lines))) (if (equal? mode "wait") '("false") '()) mode)
            (when (string? pid)
              (check-true (process-gone? pid) mode))
            (when traced?
              (check-true (regexp-match? #rx" io end code=0 signal=0" (third result)) mode)))
          (lambda ()
            (when (and (string? pid) (directory-exists? (build-path "/proc" pid)))
              (unix-kill (string->number pid) sigkill))))))

    (test-case "an output timeout keeps the captured child, and output decodes invalid UTF-8 as U+FFFD"
      (define program (build-path work "captured-output.agc"))
      (display-to-file
       (string-append
        "def main() -> Void\n"
        "  p = Result.unwrap!(Process.spawn_captured(\"/bin/sh\", [\"-c\", \"printf '\\\\377' >&2; sleep 1; echo hi\"], \".\", 60000))\n"
        "  IO.inspect(Process.output(p, 50))\n  out = Result.unwrap!(Process.output(p, 60000))\n"
        "  puts(\"#{out.stdout.inspect} #{out.stderr.length} #{String.code(out.stderr)} #{out.truncated}\")\n"
        "  Process.close(p)\nend\n")
       program)
      (define bytecode (build-path work "captured-output.agcb"))
      (compile-file program bytecode)
      (check-equal? (parameterize ([fixture-allow-run #t]) (run-vm bytecode #f #:timeout run-timeout))
                    (list 0 "error(\"network: operation timed out\")\n\"hi\\n\" 1 65533 false\n" "")))

    (test-case "a signal caught while the VM is blocked is not lost when the last child exits first"
      (define program (build-path work "signal-pending.agc"))
      (display-to-file
       (string-append
        "def main() -> Void\n  p = Result.unwrap!(Process.spawn(\"/bin/sh\", [\"-c\", \"echo $$; exec sleep 30\"], 60000))\n"
        "  puts(Result.unwrap!(Process.read_line(p, 60000)))\n  IO.flush()\n"
        "  puts(String.join(List.repeat(\"x\", 1048576), \"\"))\n  puts(\"survived\")\nend\n")
       program)
      (define bytecode (build-path work "signal-pending.agcb"))
      (compile-file program bytecode)
      (define-values (vm out in err) (subprocess #f #f #f vm-file "--allow-run" "--" (path->string bytecode)))
      (define pid #f)
      (dynamic-wind
        void
        (lambda ()
          (close-output-port in)
          (set! pid (sync/timeout run-timeout (read-line-evt out)))
          (check-pred string? pid)
          (when (string? pid)
            (sleep 0.5)
            (unix-kill (string->number pid) sigkill)
            (sleep 0.3)
            (unix-kill (subprocess-pid vm) sigterm)
            (thread (lambda () (port->bytes out)))
            (thread (lambda () (port->bytes err)))
            (check-not-false (sync/timeout run-timeout vm))
            (check-equal? (subprocess-status vm) (+ 128 sigterm))))
        (lambda ()
          (subprocess-kill vm #t)
          (when (and (string? pid) (directory-exists? (build-path "/proc" pid)))
            (unix-kill (string->number pid) sigkill)))))

    (test-case "a child does not inherit descriptors the VM inherited"
      (define program (build-path work "private-fds.agc"))
      (display-to-file
       (string-append
        "def main() -> Void\n  p = Result.unwrap!(Process.spawn(\"/bin/sh\", [\"-c\", "
        "\"if [ -e /proc/self/fd/7 ]; then echo leaked; else echo private; fi\"], 60000))\n"
        "  puts(Result.unwrap!(Process.read_line(p, 60000)))\n  Process.close(p)\nend\n")
       program)
      (define bytecode (build-path work "private-fds.agcb"))
      (compile-file program bytecode)
      (check-equal? (run-process "/bin/sh" #:timeout run-timeout "-c" "exec 7</dev/null; exec \"$0\" --allow-run -- \"$1\""
                                 (path->string vm-file) (path->string bytecode))
                    (list 0 "private\n" "")))

    (test-case "relative file paths use the raw bytes of a non-UTF-8 working directory"
      (define program (build-path work "raw-cwd.agc"))
      (display-to-file
       "def main() -> Void\n  IO.inspect(File.write_text(\"a.txt\", \"hi\", 60000))\n  IO.inspect(File.read_text(\"a.txt\", 60000))\nend\n"
       program)
      (define bytecode (build-path work "raw-cwd.agcb"))
      (compile-file program bytecode)
      (define folder (build-path work (bytes->path #"raw-\377")))
      (make-directory folder)
      (define expected (list 0 "ok()\nok(\"hi\")\n" ""))
      (parameterize ([current-directory folder])
        (check-equal? (run-vm bytecode #f) expected))
      (check-equal? (file->string (build-path folder "a.txt")) "hi")
      (delete-directory/files folder))

    (test-case "the VM decodes invalid UTF-8 arguments like Racket in a UTF-8 locale"
      (define program (build-path fixtures "system-args.agc"))
      (define bytecode (build-path work "system-args.agcb"))
      (define arguments
        (list #"\xff\xfeZ" #"\xe2\x82A" #"\xed\xa0\x80z" #"a\xe2\x82" #"\xf0\x9f\x98" #"\xe0\x80"
              #"\xf0\x80\x80" #"\xed\xa0" #"\xf4\x90" #"\xc0\xaf" #"\xe2\x82\xe2\x82" #"\xe2\x82\xac"))
      (define env (environment-variables-copy (current-environment-variables)))
      (environment-variables-set! env #"LC_ALL" #"C.UTF-8")
      (parameterize ([current-environment-variables env])
        (check-equal? (outcome (apply run-process vm-file "--" (path->string bytecode) arguments))
                      (outcome (apply run-process (find-system-path 'exec-file) (path->string main-file)
                                      (path->string program) arguments))))))

  (test-case "deep tail calls run on the VM"
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
    (check-equal? (run-vm bytecode #f) (list 0 "1000000\nfalse\n" "")))

  (test-case "String.at and slice over a long non-ASCII string on the VM"
    (define program (build-path work "string-cursor.agc"))
    (display-to-file
     (string-append
      "def main() -> Void\n  s = \"é😀\"\n  i = 0\n  while i < 15\n    s = s + s\n    i += 1\n  end\n"
      "  n = s.length\n  total = 0\n  j = 0\n  while j < n\n    total += s.at(j).code\n    j += 1\n  end\n"
      "  j = n - 1\n  while j >= 0\n    total += s.slice(j, 1).code\n    j -= 1\n  end\n"
      "  puts(\"#{n} #{total}\")\nend\n")
     program)
    (define bytecode (build-path work "string-cursor.agcb"))
    (compile-file program bytecode)
    (check-equal? (run-vm bytecode #f) (list 0 (format "65536 ~a\n" (* 2 32768 (+ 233 128512))) "")))

  (test-case "large generated input splits and decodes lines across buffer boundaries"
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
    (define (run-of n byte) (make-bytes n (char->integer byte)))
    (define input
      (bytes-append
       (run-of 65535 #\a) #"\xe2\x82\xac\n"
       (run-of 65535 #\b) #"\r\n"
       (run-of 65535 #\c) #"\rnext\n"
       (run-of 65534 #\d) #"\xf0\x9f\x98\x80\xff\xe2\x82\n"
       (apply bytes-append (for/list ([k (in-range 20000)]) (string->bytes/utf-8 (format "line ~a\r\n" k))))
       #"tail \xe2\x82"))
    (define lines (regexp-split #rx#"\r\n|\r|\n" input))
    (define stdout
      (string-append*
       (append (for/list ([line (in-list lines)] [k (in-naturals)])
                 (format "~a: \"~a\"\n" k (bytes->string/utf-8 line (integer->char #xFFFD))))
               (list "IO.gets reached the end of input\n" (format "~a\n" (add1 (length lines)))))))
    (parameterize ([fixture-input input])
      (define full (list 0 stdout "" #f))
      (check-equal? (outcome (run-vm bytecode #f)) full "large input")
      (for ([limit (in-list '(1 50 100000 400000))])
        (check-limited (run-vm bytecode limit #:timeout run-timeout) full "large input" limit))))

  (test-case "a CRLF program under a non-ASCII path gives the expected outcome"
    (define folder (build-path work "dír-λ-𝔸"))
    (make-directory folder)
    (define program (build-path folder "división-日本.agc"))
    (define text (file->string (build-path fixtures "division-by-zero.agc")))
    (call-with-output-file program
      (lambda (out) (write-string (string-replace text "\n" "\r\n") out)))
    (define bytecode (build-path folder "división-日本.agcb"))
    (compile-file program bytecode)
    (define full (read-expected (build-path fixtures "division-by-zero.agc")))
    (check-equal? (fourth full) "RUNTIME-DIVISION-BY-ZERO")
    (for ([style (in-list '(plain ai json))])
      (define on-vm (run-vm bytecode #f #:style style))
      (if (eq? style 'json)
          (check-equal? (outcome on-vm) full (format "~a" style))
          (check-text-format on-vm full (format "~a" style))))
    (define total (total-steps bytecode))
    (define expected-steps (read-expected-steps (build-path fixtures "division-by-zero.agc")))
    (check-steps total expected-steps "CRLF program")
    (define limits (list 1 (sub1 total) total (last-limit expected-steps)))
    (check-sweep (for/list ([limit (in-list limits)]) (run-vm bytecode limit #:timeout run-timeout)) limits full "CRLF program")))

(define (check-selected)
  (check-fixture-filter)
  (unless fixture-filter
    (eprintf "vm-diff: check needs AGENTICA_FIXTURES (make vm-golden-check FIXTURES=\"name ...\")\n")
    (exit 2))
  (unless (vm-built?) (exit 1))
  (define work (make-temporary-directory "agentica-vm~a"))
  (dynamic-wind
    void
    (lambda ()
      (parameterize ([tmp-root work])
        (for ([program (in-list (select-programs (fixture-programs)))])
          (run-fixture work program))
        (for ([program (in-list (select-programs (runaway-programs)))])
          (test-case (format "~a stops at --max-steps with a prefix of its expected output" (fixture-name program))
            (check-runaway work program)))))
    (lambda () (delete-directory/files work)))
  (define results (test-log #:display? #f #:exit? #f))
  (printf "vm-diff check: ~a of ~a checks failed\n" (car results) (cdr results))
  (when (zero? (cdr results))
    (eprintf "vm-diff: no checks ran (a skipped fixture?)\n")
    (exit 1))
  (unless (zero? (car results))
    (exit 1)))

(define (write-goldens)
  (check-fixture-filter)
  (unless (vm-built?) (exit 1))
  (define work (make-temporary-directory "agentica-goldens~a"))
  (define (save program result [steps #f])
    (define seen (outcome result))
    (unless (and (exact-integer? (first seen)) (not (< 128 (first seen) 160)))
      (error 'vm-golden "~a did not finish (timeout or signal): ~s" program result))
    (when (equal? (fourth seen) "RUNTIME-INTERNAL")
      (error 'vm-golden "~a failed with RUNTIME-INTERNAL: ~s" program result))
    (call-with-output-file (expected-file program) #:exists 'truncate/replace
      (lambda (out) (write-string (expected->string seen steps) out))))
  (for ([directory (list fixtures (build-path fixtures "step-limited"))])
    (for ([file (in-list (directory-list directory #:build? #t))]
          #:when (and (path-has-extension? file #".expected")
                      (not (file-exists? (path-replace-extension file #".agc")))))
      (eprintf "~a has no .agc next to it; delete it\n" file)))
  (dynamic-wind
    void
    (lambda ()
      (parameterize ([tmp-root work])
        (for ([program (in-list (select-programs (fixture-programs)))])
          (define bytecode (fixture-bytecode work program))
          (call-with-fixture program
                             (lambda () (save program (run-fixture-vm bytecode #f) (total-steps bytecode)))))
        (for ([program (in-list (select-programs (runaway-programs)))])
          (save program (run-vm (fixture-bytecode work program) runaway-limit #:timeout run-timeout)))))
    (lambda () (delete-directory/files work))))

(module+ main
  (match (vector->list (current-command-line-arguments))
    ['() (write-goldens)]
    ['("check") (check-selected)]
    [_ (eprintf "usage: racket tests/vm-diff-common.rkt [check]\n")
       (exit 2)]))
