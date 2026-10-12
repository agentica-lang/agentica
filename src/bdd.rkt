#lang racket

(require racket/async-channel racket/runtime-path "diagnostic.rkt" "json.rkt")

(provide (struct-out bdd-result) (struct-out bdd-context) (struct-out exn:fail:bdd)
         make-bdd-context default-bdd-command bdd-call bdd-cleanup! bdd-limit bdd-output-problem compile-step-pattern match-step-pattern)

(struct bdd-result (ok? value) #:transparent)
(struct bdd-context (base command state child custodian assertions doc table deadline
                          state-lock input-lock output-lock lifecycle-lock) #:mutable)
(struct child (process input output stdout stderr workers overflow) #:transparent)
(struct exn:fail:bdd exn:fail (problem) #:transparent)

(define-runtime-path main-program "main.rkt")

(define (default-bdd-command)
  (append
   (if (path? (variable-reference->module-source (#%variable-reference)))
       (list (or (find-executable-path "racket") (error 'BDD "Racket is not installed")) main-program)
       (list (path->complete-path (find-system-path 'exec-file))))
   '("--legacy-eval")))

(define (make-bdd-context base [command (default-bdd-command)])
  (bdd-context base command (make-hash) #f (make-custodian) 0 #f #f
               (+ (current-inexact-monotonic-milliseconds) 30000)
               (make-semaphore 1) (make-semaphore 1) (make-semaphore 1) (make-semaphore 1)))

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
  (define operation-custodian (make-custodian))
  (dynamic-wind void
    (lambda ()
      (parameterize ([current-custodian operation-custodian]
                     [current-subprocess-custodian-mode 'kill])
        (thread (lambda ()
                  (async-channel-put result
                    (with-handlers ([exn? values]) (box (thunk)))))))
      (define answer (sync/timeout (/ (max 0 (min timeout remaining)) 1000.0) result))
      (unless answer
        (bdd-fail 'RUNTIME-BDD-TIMEOUT "BDD operation timed out" span))
      (if (exn? answer) (raise answer) (unbox answer)))
    (lambda () (custodian-shutdown-all operation-custodian))))

(define (bdd-cleanup! context)
  (define target (bdd-context-child context))
  (when target
    (with-handlers ([exn:fail? void])
      (when (eq? (subprocess-status (child-process target)) 'running)
        (subprocess-kill (child-process target) #t))
      (subprocess-wait (child-process target)))
    (with-handlers ([exn:fail? void]) (close-output-port (child-input target))))
  (custodian-shutdown-all (bdd-context-custodian context)))

(define (start-program! context path span)
  (when (bdd-context-child context)
    (bdd-fail 'RUNTIME-BDD-CONTEXT "only one program may start per scenario" span))
  (define source-path (simplify-path (path->complete-path path (bdd-context-base context))))
  (unless (and (file-exists? source-path) (equal? (path-get-extension source-path) #".agc"))
    (bdd-fail 'RUNTIME-BDD-PROGRAM "expected an existing .agc program" span))
  (define command (bdd-context-command context))
  (unless (and (pair? command) (file-exists? (car command)))
    (bdd-fail 'RUNTIME-BDD-INFRA "Agentica executable is unavailable" span))
  (let ()
    (define-values (process output input errors)
      (parameterize ([current-custodian (bdd-context-custodian context)]
                     [current-subprocess-custodian-mode 'kill]
                     [current-directory (bdd-context-base context)])
        (apply subprocess #f #f #f (car command)
               (append (cdr command) (list "--max-steps" "1000000" (path->string source-path))))))
    (define-values (line-input line-output)
      (parameterize ([current-custodian (bdd-context-custodian context)]) (make-pipe)))
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
    (set-bdd-context-child! context (child process input line-input stdout stderr workers overflow))))

(define (bdd-call context name arguments span)
  (with-handlers ([exn:fail:bdd? exn:fail:bdd-problem]
                  [exn:fail? (lambda (failure) (diagnostic 'RUNTIME-BDD-IO (exn-message failure) span))])
    (define (invoke) (bdd-call/unlocked context name arguments span))
    (define (locked semaphore timeout)
      (bdd-limit context (lambda () (call-with-semaphore semaphore invoke)) timeout span))
    (cond
      [(member name '("BDD.set" "BDD.get" "BDD.assert"))
       (call-with-semaphore (bdd-context-state-lock context) invoke)]
      [(equal? name "BDD.given_program")
       (locked (bdd-context-lifecycle-lock context) 30000)]
      [(member name '("BDD.when_line" "BDD.when_input" "BDD.when_eof"))
       (locked (bdd-context-input-lock context) 5000)]
      [(member name '("BDD.then_line" "BDD.then_json_line"))
       (locked (bdd-context-output-lock context) (cadr arguments))]
      [(member name '("BDD.then_stdout" "BDD.then_stderr"))
       (locked (bdd-context-output-lock context) 5000)]
      [else (invoke)])))

(define (bdd-call/unlocked context name arguments span)
  (with-handlers ([exn:fail:bdd? exn:fail:bdd-problem]
                  [exn:fail? (lambda (failure) (diagnostic 'RUNTIME-BDD-IO (exn-message failure) span))])
    (define (fail message) (bdd-fail 'RUNTIME-BDD-CONTEXT message span))
    (define (target!)
      (define target (bdd-context-child context))
      (unless target (fail "start a program before using its streams"))
      (unless (child-process target) (fail "program startup is not complete"))
      (define problem (bdd-output-problem context span))
      (when problem (raise (exn:fail:bdd (diagnostic-message problem) (current-continuation-marks) problem)))
      target)
    (define (assert! condition expected actual)
      (call-with-semaphore (bdd-context-state-lock context)
        (lambda ()
          (set-bdd-context-assertions! context (add1 (bdd-context-assertions context)))))
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
      [("BDD.set") (hash-set! (bdd-context-state context) (car arguments) (cadr arguments)) (void)]
      [("BDD.get")
       (if (hash-has-key? (bdd-context-state context) (car arguments))
           (bdd-result #t (hash-ref (bdd-context-state context) (car arguments)))
           (bdd-result #f "missing scenario state"))]
      [("BDD.assert")
       (set-bdd-context-assertions! context (add1 (bdd-context-assertions context)))
       (unless (car arguments) (bdd-fail 'RUNTIME-BDD-ASSERTION (cadr arguments) span))
       (void)]
      [("BDD.given_program") (start-program! context (car arguments) span) (void)]
      [("BDD.when_line" "BDD.when_input")
       (define target (target!))
       (when (port-closed? (child-input target)) (fail "stdin is already closed"))
       (bdd-limit context
         (lambda ()
           (display (car arguments) (child-input target))
           (when (equal? name "BDD.when_line") (newline (child-input target)))
           (flush-output (child-input target))) 5000 span)
       (void)]
      [("BDD.when_eof")
       (define target (target!))
       (when (port-closed? (child-input target)) (fail "stdin is already closed"))
       (bdd-limit context (lambda () (close-output-port (child-input target))) 5000 span)
       (void)]
      [("BDD.then_line")
       (define actual (read-line!))
       (assert! (equal? actual (car arguments)) (car arguments) actual)
       (void)]
      [("BDD.then_json_line")
       (define actual (read-line!))
       (define-values (expected-data actual-data)
         (with-handlers ([exn:fail? (lambda (_) (bdd-fail 'RUNTIME-BDD-JSON "expected and received lines must be valid JSON" span))])
           (values (json-value-data (read-json-value (car arguments))) (json-value-data (read-json-value actual)))))
       (assert! (equal? expected-data actual-data) (car arguments) actual)
       (void)]
      [("BDD.then_stdin_open")
       (define target (target!))
       (assert! (and (not (port-closed? (child-input target)))
                     (eq? (subprocess-status (child-process target)) 'running)) "open stdin and active program" "closed stdin or stopped program")
       (void)]
      [("BDD.then_exit")
       (define target (target!))
       (bdd-limit context
         (lambda ()
           (subprocess-wait (child-process target))
           (for-each thread-wait (child-workers target))) (cadr arguments) span)
       (target!)
       (define actual (subprocess-status (child-process target)))
       (assert! (equal? actual (car arguments)) (number->string (car arguments)) (format "~a" actual))
       (void)]
      [("BDD.then_stdout" "BDD.then_stderr")
       (define target (target!))
       (when (eq? (subprocess-status (child-process target)) 'running)
         (fail "complete output requires program exit"))
       (bdd-limit context (lambda () (for-each thread-wait (child-workers target))) 5000 span)
       (target!)
       (define actual (bytes->string/utf-8 (get-output-bytes (if (equal? name "BDD.then_stdout") (child-stdout target) (child-stderr target))) #f))
       (assert! (equal? actual (car arguments)) (car arguments) actual)
       (void)]
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
