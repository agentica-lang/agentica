#lang racket

(require racket/async-channel "diagnostic.rkt" "json.rkt")

(provide (struct-out bdd-result) (struct-out bdd-context) (struct-out exn:fail:bdd)
         make-bdd-context bdd-call bdd-cleanup! bdd-limit bdd-output-problem compile-step-pattern match-step-pattern)

(struct bdd-result (ok? value) #:transparent)
(struct bdd-context (base image runtime state child custodian assertions doc table deadline) #:mutable)
(struct child (name process input output stdout stderr workers directory overflow) #:transparent)
(struct exn:fail:bdd exn:fail (problem) #:transparent)

(define (make-bdd-context base image runtime)
  (bdd-context base image runtime (make-hash) #f (make-custodian) 0 #f #f
               (+ (current-inexact-monotonic-milliseconds) 30000)))

(define (bdd-output-problem context span)
  (define target (bdd-context-child context))
  (define issue (and target (unbox (child-overflow target))))
  (cond
    [(exn:fail? issue) (diagnostic 'RUNTIME-BDD-IO (exn-message issue) span)]
    [issue (diagnostic 'RUNTIME-BDD-OUTPUT-LIMIT "program output exceeds 1 MiB" span)]
    [else #f]))

(define (bdd-fail code message span #:expected [expected #f] #:actual [actual #f])
  (raise (exn:fail:bdd message (current-continuation-marks)
                      (diagnostic code message span #:expected expected #:actual actual))))

(define (bdd-limit context thunk timeout span)
  (unless (exact-positive-integer? timeout)
    (bdd-fail 'RUNTIME-BDD-TIMEOUT "timeout must be a positive integer" span))
  (define remaining (- (bdd-context-deadline context) (current-inexact-monotonic-milliseconds)))
  (define result (make-async-channel))
  (define worker
    (parameterize ([current-custodian (bdd-context-custodian context)]
                   [current-subprocess-custodian-mode 'kill])
      (thread (lambda ()
                (async-channel-put result
                  (with-handlers ([exn? values]) (box (thunk))))))))
  (define answer (sync/timeout (/ (max 0 (min timeout remaining)) 1000.0) result))
  (unless answer
    (kill-thread worker)
    (bdd-fail 'RUNTIME-BDD-TIMEOUT "BDD operation timed out" span))
  (if (exn? answer) (raise answer) (unbox answer)))

(define (docker-command context arguments span)
  (define docker (find-executable-path "docker"))
  (unless docker (bdd-fail 'RUNTIME-BDD-INFRA "Docker is not installed" span))
  (bdd-limit context
    (lambda ()
      (define-values (process output input errors) (apply subprocess #f #f #f docker arguments))
      (dynamic-wind void
        (lambda ()
          (close-output-port input)
          (define out-result (make-async-channel))
          (define err-result (make-async-channel))
          (define out-reader (thread (lambda () (async-channel-put out-result (with-handlers ([exn:fail? values]) (port->string output))))))
          (define err-reader (thread (lambda () (async-channel-put err-result (with-handlers ([exn:fail? values]) (port->string errors))))))
          (subprocess-wait process)
          (define out-text (sync out-result))
          (define err-text (sync err-result))
          (when (exn:fail? out-text) (raise out-text))
          (when (exn:fail? err-text) (raise err-text))
          (thread-wait out-reader)
          (thread-wait err-reader)
          (unless (zero? (subprocess-status process))
            (bdd-fail 'RUNTIME-BDD-INFRA (string-append "Docker failed: " (string-trim err-text)) span))
          out-text)
        (lambda ()
          (when (eq? (subprocess-status process) 'running) (subprocess-kill process #t))
          (close-input-port output)
          (close-input-port errors))))
    5000 span))

(define (bdd-cleanup! context)
  (define target (bdd-context-child context))
  (when target
    (with-handlers ([exn:fail? void])
      (define docker (find-executable-path "docker"))
      (when docker
        (define-values (process output input errors)
          (subprocess #f #f #f docker "rm" "--force" (child-name target)))
        (close-output-port input)
        (unless (sync/timeout 5 process) (subprocess-kill process #t))
        (close-input-port output)
        (close-input-port errors)))
    (with-handlers ([exn:fail? void])
      (when (eq? (subprocess-status (child-process target)) 'running)
        (subprocess-kill (child-process target) #t)))
    (with-handlers ([exn:fail? void]) (close-output-port (child-input target))))
  (custodian-shutdown-all (bdd-context-custodian context))
  (when target
    (with-handlers ([exn:fail? void]) (delete-directory/files (child-directory target)))))

(define (start-program! context path span)
  (when (bdd-context-child context)
    (bdd-fail 'RUNTIME-BDD-CONTEXT "only one program may start per scenario" span))
  (define source-path (simplify-path (path->complete-path path (bdd-context-base context))))
  (unless (and (file-exists? source-path) (equal? (path-get-extension source-path) #".agc"))
    (bdd-fail 'RUNTIME-BDD-PROGRAM "expected an existing .agc program" span))
  (define runtime (path->complete-path (bdd-context-runtime context)))
  (unless (file-exists? (build-path runtime "bin" "agentica"))
    (bdd-fail 'RUNTIME-BDD-INFRA "runtime missing; run make bdd-prepare" span))
  (docker-command context (list "image" "inspect" (bdd-context-image context)) span)
  (define directory (make-temporary-file "agentica-bdd-~a" 'directory))
  (define name (path->string (file-name-from-path directory)))
  (set-bdd-context-child! context (child name #f #f #f #f #f '() directory (box #f)))
  (with-handlers ([exn? (lambda (failure) (delete-directory/files directory) (raise failure))])
    (file-or-directory-permissions directory #o755)
    (copy-file source-path (build-path directory "target.agc"))
    (file-or-directory-permissions (build-path directory "target.agc") #o644)
    (docker-command context
      (list "create" "--interactive" "--name" name "--user" "65534:65534"
            "--read-only" "--cap-drop=ALL" "--security-opt=no-new-privileges"
            "--pids-limit=256" "--memory=2g" "--cpus=2" "--network=none"
            "--tmpfs" "/tmp:rw,nosuid,nodev,size=128m"
            "--tmpfs" "/home/agent:rw,nosuid,nodev,uid=65534,gid=65534,size=128m"
            "--mount" (format "type=bind,src=~a,dst=/workspace,readonly" directory)
            "--mount" (format "type=bind,src=~a,dst=/runtime,readonly" runtime)
            "--workdir" "/workspace" "--env" "LANG=C.UTF-8"
            (bdd-context-image context) "/runtime/bin/agentica" "--max-steps" "1000000" "/workspace/target.agc") span)
    (define-values (process output input errors)
      (parameterize ([current-custodian (bdd-context-custodian context)]
                     [current-subprocess-custodian-mode 'kill])
        (subprocess #f #f #f (find-executable-path "docker") "start" "--attach" "--interactive" name)))
    (define-values (line-input line-output) (make-pipe))
    (define stdout (open-output-bytes))
    (define stderr (open-output-bytes))
    (define overflow (box #f))
    (define (drain port capture relay)
      (parameterize ([current-custodian (bdd-context-custodian context)])
        (thread
          (lambda ()
            (dynamic-wind void
              (lambda ()
                (define buffer (make-bytes 4096))
                (with-handlers ([exn:fail? (lambda (failure) (set-box! overflow failure))])
                  (let loop ([count 0])
                    (define size (read-bytes-avail! buffer port))
                    (unless (eof-object? size)
                      (define data (subbytes buffer 0 size))
                      (if (> (+ count (bytes-length data)) 1048576)
                          (set-box! overflow #t)
                          (begin
                            (write-bytes data capture)
                            (when relay (write-bytes data relay))
                            (loop (+ count (bytes-length data)))))))))
              (lambda ()
                (close-input-port port)
                (when relay (close-output-port relay))))))))
    (define workers (list (drain output stdout line-output) (drain errors stderr #f)))
    (set-bdd-context-child! context (child name process input line-input stdout stderr workers directory overflow))
    (bdd-limit context
      (lambda ()
        (let wait-start ()
          (define state (string-trim (docker-command context (list "inspect" "--format" "{{.State.Status}}" name) span)))
          (unless (member state '("running" "exited" "dead"))
            (sleep 0.02)
            (wait-start))))
      5000 span)))

(define (bdd-call context name arguments span)
  (with-handlers ([exn:fail:bdd? exn:fail:bdd-problem]
                  [exn:fail? (lambda (failure) (diagnostic 'RUNTIME-BDD-IO (exn-message failure) span))])
    (define (fail message) (bdd-fail 'RUNTIME-BDD-CONTEXT message span))
    (define (target!)
      (define target (bdd-context-child context))
      (unless target (fail "start a program before using its streams"))
      (define problem (bdd-output-problem context span))
      (when problem (raise (exn:fail:bdd (diagnostic-message problem) (current-continuation-marks) problem)))
      target)
    (define (assert! condition expected actual)
      (set-bdd-context-assertions! context (add1 (bdd-context-assertions context)))
      (unless condition
        (bdd-fail 'RUNTIME-BDD-ASSERTION "BDD assertion failed" span #:expected expected #:actual actual)))
    (define (read-line!)
      (define target (target!))
      (define value (bdd-limit context (lambda () (read-bytes-line (child-output target) 'any)) (cadr arguments) span))
      (target!)
      (when (eof-object? value)
        (bdd-fail 'RUNTIME-BDD-ASSERTION "stdout ended before the expected line" span))
      (bytes->string/utf-8 value #f))
    (case name
      [("BDD.doc_string") (or (bdd-context-doc context) (fail "this step has no Doc String"))]
      [("BDD.table") (or (bdd-context-table context) (fail "this step has no Data Table"))]
      [("BDD.set") (hash-set! (bdd-context-state context) (car arguments) (cadr arguments)) 'nil]
      [("BDD.get")
       (if (hash-has-key? (bdd-context-state context) (car arguments))
           (bdd-result #t (hash-ref (bdd-context-state context) (car arguments)))
           (bdd-result #f "missing scenario state"))]
      [("BDD.assert")
       (set-bdd-context-assertions! context (add1 (bdd-context-assertions context)))
       (unless (car arguments) (bdd-fail 'RUNTIME-BDD-ASSERTION (cadr arguments) span))
       'nil]
      [("BDD.given_program") (start-program! context (car arguments) span) 'nil]
      [("BDD.when_line" "BDD.when_input")
       (define target (target!))
       (when (port-closed? (child-input target)) (fail "stdin is already closed"))
       (bdd-limit context
         (lambda ()
           (display (car arguments) (child-input target))
           (when (equal? name "BDD.when_line") (newline (child-input target)))
           (flush-output (child-input target))) 5000 span)
       'nil]
      [("BDD.when_eof")
       (define target (target!))
       (when (port-closed? (child-input target)) (fail "stdin is already closed"))
       (bdd-limit context (lambda () (close-output-port (child-input target))) 5000 span)
       'nil]
      [("BDD.then_line")
       (define actual (read-line!))
       (assert! (equal? actual (car arguments)) (car arguments) actual)
       'nil]
      [("BDD.then_json_line")
       (define actual (read-line!))
       (define-values (expected-data actual-data)
         (with-handlers ([exn:fail? (lambda (_) (bdd-fail 'RUNTIME-BDD-JSON "expected and received lines must be valid JSON" span))])
           (values (json-value-data (read-json-value (car arguments))) (json-value-data (read-json-value actual)))))
       (assert! (equal? expected-data actual-data) (car arguments) actual)
       'nil]
      [("BDD.then_stdin_open")
       (define target (target!))
       (define running? (equal? "true" (string-trim (docker-command context (list "inspect" "--format" "{{.State.Running}}" (child-name target)) span))))
       (assert! (and (not (port-closed? (child-input target)))
                     (eq? (subprocess-status (child-process target)) 'running) running?) "open stdin and active program" "closed stdin or stopped program")
       'nil]
      [("BDD.then_exit")
       (define target (target!))
       (bdd-limit context
         (lambda ()
           (subprocess-wait (child-process target))
           (for-each thread-wait (child-workers target))) (cadr arguments) span)
       (target!)
       (unless (equal? "exited" (string-trim (docker-command context (list "inspect" "--format" "{{.State.Status}}" (child-name target)) span)))
         (bdd-fail 'RUNTIME-BDD-INFRA "Docker attachment ended before program exit" span))
       (define actual (string->number (string-trim (docker-command context (list "inspect" "--format" "{{.State.ExitCode}}" (child-name target)) span))))
       (assert! (equal? actual (car arguments)) (number->string (car arguments)) (format "~a" actual))
       'nil]
      [("BDD.then_stdout" "BDD.then_stderr")
       (define target (target!))
       (when (eq? (subprocess-status (child-process target)) 'running)
         (fail "complete output requires program exit"))
       (unless (equal? "exited" (string-trim (docker-command context (list "inspect" "--format" "{{.State.Status}}" (child-name target)) span)))
         (fail "complete output requires program exit"))
       (bdd-limit context (lambda () (for-each thread-wait (child-workers target))) 5000 span)
       (target!)
       (define actual (bytes->string/utf-8 (get-output-bytes (if (equal? name "BDD.then_stdout") (child-stdout target) (child-stderr target))) #f))
       (assert! (equal? actual (car arguments)) (car arguments) actual)
       'nil]
      [else (fail "builtin is unavailable during scenario execution")])))

(define (compile-step-pattern pattern)
  (define captures '())
  (define pieces '())
  (define position 0)
  (for ([match (in-list (regexp-match-positions* #px"\\{[^{}]*\\}" pattern))])
    (set! pieces (cons (regexp-quote (substring pattern position (car match))) pieces))
    (define kind (substring pattern (add1 (car match)) (sub1 (cdr match))))
    (unless (member kind '("string" "int")) (error 'BDD.step "only {string} and {int} are supported"))
    (set! captures (cons kind captures))
    (set! pieces (cons (if (equal? kind "int") "(-?[0-9]+)" "(\"(?:[^\"\\\\]|\\\\.)*\"|'(?:[^'\\\\]|\\\\.)*')") pieces))
    (set! position (cdr match)))
  (define tail (substring pattern position))
  (when (regexp-match? #px"[{}]" (regexp-replace* #px"\\{(?:string|int)\\}" pattern ""))
    (error 'BDD.step "unmatched pattern braces"))
  (cons (pregexp (string-append "^" (apply string-append (reverse (cons (regexp-quote tail) pieces))) "$"))
        (reverse captures)))

(define (match-step-pattern compiled text)
  (define matched (regexp-match (car compiled) text))
  (and matched
       (for/list ([value (in-list (cdr matched))] [kind (in-list (cdr compiled))])
         (if (equal? kind "int") value
             (regexp-replace* #px"\\\\(.)" (substring value 1 (sub1 (string-length value)))
                              (lambda (whole ch) ch))))))
