#lang racket

(require "ast.rkt" "bdd.rkt" "checker.rkt" "diagnostic.rkt" "evaluator.rkt"
         "gherkin.rkt" "json.rkt" "lexer.rkt" "parser.rkt" "source.rkt" "process.rkt" "modules.rkt")

(provide run-bdd make-bdd-service format-bdd-report bdd-error-report)

(struct definition (pattern compiled execute) #:transparent)

(define (bdd-error-report problem)
  (define path (source-name (source-span-source (diagnostic-span problem))))
  (hasheq 'ok #f 'passed 0 'failed 0 'not_executed 0 'file_errors 1 'exit_code 2
          'files (list (hasheq 'path path 'feature "" 'status "failed" 'scenarios '()
                               'error (diagnostic->jsexpr problem)))))

(define (file-span path)
  (source-span (source (path->string (path->complete-path path)) "")
               (source-position 0 1 1) (source-position 0 1 1)))

(define (read-program path)
  (with-handlers ([exn:fail? (lambda (failure) (diagnostic 'RUNTIME-BDD-INFRA (exn-message failure) (file-span path)))])
    (define linked (load-program path))
    (if (diagnostic? linked) linked (check linked))))

(define (guard context span thunk)
  (with-handlers ([exn:fail:bdd? exn:fail:bdd-problem]
                  [exn:fail? (lambda (failure) (diagnostic 'RUNTIME-BDD-IO (exn-message failure) span))])
    (parameterize ([current-custodian (bdd-context-custodian context)])
      (bdd-limit context thunk 30000 span))))

(define (quiet-output)
  (define count 0)
  (define lock (make-semaphore 1))
  (make-output-port 'bdd-output always-evt
    (lambda (data start end non-block? breakable?)
      (call-with-semaphore lock
        (lambda ()
          (set! count (+ count (- end start)))
          (when (> count 1048576) (error 'BDD "handler output exceeds 1 MiB"))
          (- end start)))) void))

(define current-bdd-seed (make-parameter #f))

(define (evaluate-handler program context handler #:entrypoint [entrypoint "main"] #:arguments [arguments '()])
  (evaluate program #:in (open-input-string "") #:out (quiet-output) #:err (quiet-output)
            #:entrypoint entrypoint #:arguments arguments #:max-steps 1000000 #:builtin-handler handler
            #:require-complete-tasks? #t #:seed (current-bdd-seed)))

(define (built-in-definitions)
  (define (entry pattern name build-arguments)
    (definition pattern (compile-step-pattern pattern)
      (lambda (context captures span)
        (bdd-call context name (build-arguments context captures) span))))
  (define (doc context)
    (or (bdd-context-doc context) (error 'BDD "step needs a Doc String")))
  (list
    (entry "the Agentica program {string}" "BDD.given_program" (lambda (context args) args))
    (entry "I send a line:" "BDD.when_line" (lambda (context args) (list (doc context))))
    (entry "I send the line {string}" "BDD.when_line" (lambda (context args) args))
    (entry "I send input:" "BDD.when_input" (lambda (context args) (list (doc context))))
    (entry "I close stdin" "BDD.when_eof" (lambda (context args) '()))
    (entry "I receive a line within {int} milliseconds:" "BDD.then_line"
           (lambda (context args) (list (doc context) (string->number (car args)))))
    (entry "I receive the line {string} within {int} milliseconds" "BDD.then_line"
           (lambda (context args) (list (car args) (string->number (cadr args)))))
    (entry "I receive a JSON line within {int} milliseconds:" "BDD.then_json_line"
           (lambda (context args) (list (doc context) (string->number (car args)))))
    (entry "stdin remains open" "BDD.then_stdin_open" (lambda (context args) '()))
    (entry "the program exits with code {int} within {int} milliseconds" "BDD.then_exit"
           (lambda (context args) (map string->number args)))
    (entry "stdout is:" "BDD.then_stdout" (lambda (context args) (list (doc context))))
    (entry "stderr is:" "BDD.then_stderr" (lambda (context args) (list (doc context))))))

(define (load-definitions path registry command)
  (define program (read-program path))
  (if (diagnostic? program) program
      (let ()
        (define additions '())
        (define registration-lock (make-semaphore 1))
        (define context (make-bdd-context (or (path-only (path->complete-path path)) (current-directory)) command))
        (define result
          (dynamic-wind void
            (lambda ()
              (guard context (program-span program)
                (lambda ()
                  (evaluate-handler program context
                    (lambda (name arguments span)
                      (call-with-semaphore registration-lock
                        (lambda () (cond
                        [(not (equal? name "BDD.step"))
                         (diagnostic 'RUNTIME-BDD-CONTEXT "handler main may only register BDD.step definitions" span)]
                        [(member (car arguments) (map definition-pattern (append registry additions)))
                         (diagnostic 'RUNTIME-BDD-DUPLICATE "duplicate step pattern" span)]
                        [else
                         (with-handlers ([exn:fail? (lambda (failure) (diagnostic 'RUNTIME-BDD-PATTERN (exn-message failure) span))])
                           (define pattern (car arguments))
                           (define callback (cadr arguments))
                           (set! additions
                             (cons (definition pattern (compile-step-pattern pattern)
                                     (lambda (scenario-context captures step-span)
                                       (evaluate-handler program scenario-context
                                         (lambda (builtin args where) (bdd-call scenario-context builtin args where))
                                         #:entrypoint callback #:arguments (list captures)))) additions))
                           (void))]))))))))
            (lambda () (bdd-cleanup! context))))
        (cond
          [(diagnostic? result) result]
          [(exit-code? result) (diagnostic 'RUNTIME-BDD-PREMATURE-EXIT "handler registration exited prematurely" (program-span program))]
          [else (reverse additions)]))))

(define (resolve action registry)
  (define matches
    (for/list ([entry (in-list registry)]
               #:do [(define captures (match-step-pattern (definition-compiled entry) (step-text action)))]
               #:when captures)
      (cons entry captures)))
  (cond
    [(null? matches) (diagnostic 'CHECK-BDD-UNDEFINED "no step definition matches" (step-span action) #:actual (step-text action))]
    [(pair? (cdr matches)) (diagnostic 'CHECK-BDD-AMBIGUOUS "multiple step definitions match" (step-span action) #:actual (step-text action))]
    [else (car matches)]))

(define (location->jsexpr span)
  (define start (source-span-start span))
  (hasheq 'file (source-name (source-span-source span)) 'line (source-position-line start) 'column (source-position-column start)))

(define (run-scenario item feature-path registry command)
  (define started (current-inexact-monotonic-milliseconds))
  (define actions (scenario-steps item))
  (define bindings (map (lambda (action) (resolve action registry)) actions))
  (define preflight (findf diagnostic? bindings))
  (define context (make-bdd-context (path-only (path->complete-path feature-path)) command))
  (define failure preflight)
  (define records '())
  (dynamic-wind void
    (lambda ()
      (for ([action (in-list actions)] [binding (in-list bindings)])
        (define problem
          (cond
            [failure (if (eq? binding preflight) preflight #f)]
            [else
             (set-bdd-context-doc! context (step-doc action))
             (set-bdd-context-table! context (step-table action))
             (define before (bdd-context-assertions context))
             (define value
               (guard context (step-span action)
                 (lambda () ((definition-execute (car binding)) context (cdr binding) (step-span action)))))
             (cond
               [(diagnostic? value) value]
               [(bdd-output-problem context (step-span action)) => values]
               [(exit-code? value) (diagnostic 'RUNTIME-BDD-PREMATURE-EXIT "step exited prematurely" (step-span action))]
               [(and (eq? (step-kind action) 'Then) (= before (bdd-context-assertions context)))
                (diagnostic 'RUNTIME-BDD-NO-ASSERTION "Then must perform a BDD assertion" (step-span action))]
               [else #f])]))
        (define status (cond [problem "failed"] [failure "not_executed"] [else "passed"]))
        (set! records (cons (hasheq 'text (step-text action) 'status status 'location (location->jsexpr (step-span action))
                                    'error (if problem (diagnostic->jsexpr problem) 'null)) records))
        (when problem (set! failure problem)))
      (unless (or failure (positive? (bdd-context-assertions context)))
        (set! failure (diagnostic 'RUNTIME-BDD-NO-ASSERTION "scenario performed no BDD assertions" (scenario-span item)))))
    (lambda () (bdd-cleanup! context)))
  (unless failure (set! failure (bdd-output-problem context (scenario-span item))))
  (hasheq 'name (scenario-name item) 'status (if failure "failed" "passed")
          'tags (scenario-tags item) 'location (location->jsexpr (scenario-span item))
          'example (if (scenario-example-span item) (location->jsexpr (scenario-example-span item)) 'null)
          'duration_ms (inexact->exact (round (- (current-inexact-monotonic-milliseconds) started)))
          'steps (reverse records) 'error (if failure (diagnostic->jsexpr failure) 'null)))

(define (run-bdd paths #:steps [step-files '()] #:command [base-command (default-bdd-command)]
                 #:allow-run [allow-run? (current-process-allowed?)] #:seed [seed #f])
  (parameterize ([current-process-allowed? allow-run?]
                 [current-bdd-seed seed])
  (define command
    (append base-command
            (if allow-run? '("--allow-run") '())
            (if seed (list "--seed" (number->string seed)) '())))
  (define files '())
  (define registry (built-in-definitions))
  (define targets '())
  (define (file-error path problem)
    (set! files (cons (hasheq 'path (path->string (path->complete-path path)) 'feature "" 'status "failed"
                              'scenarios '() 'error (diagnostic->jsexpr problem)) files)))
  (for ([path (in-list step-files)])
    (define result (load-definitions path registry command))
    (if (diagnostic? result) (file-error path result) (set! registry (append registry result))))
  (for ([path (in-list paths)])
    (cond
      [(directory-exists? path)
       (set! targets (append targets (for/list ([candidate (in-directory path)]
                                               #:when (and (file-exists? candidate) (equal? (path-get-extension candidate) #".feature")))
                                      (simplify-path (path->complete-path candidate)))))]
      [(file-exists? path) (set! targets (cons (simplify-path (path->complete-path path)) targets))]
      [else (file-error path (diagnostic 'RUNTIME-BDD-INFRA "feature path does not exist" (file-span path)))]))
  (when (and (null? targets) (null? files))
    (file-error (if (null? paths) "specs" (car paths)) (diagnostic 'CHECK-BDD-EMPTY "no .feature files found" (file-span "specs"))))
  (for ([path (in-list (sort (remove-duplicates targets) string<? #:key path->string))])
    (define parsed
      (with-handlers ([exn:fail? (lambda (failure) (diagnostic 'RUNTIME-BDD-INFRA (exn-message failure) (file-span path)))])
        (parse-gherkin (source (path->string path) (file->string path)))))
    (cond
      [(diagnostic? parsed) (file-error path parsed)]
      [else
       (define results (for/list ([item (in-list (feature-scenarios parsed))]) (run-scenario item path registry command)))
       (set! files (cons (hasheq 'path (path->string path) 'feature (feature-name parsed)
                                 'status (if (andmap (lambda (item) (equal? (hash-ref item 'status) "passed")) results) "passed" "failed")
                                 'scenarios results 'error 'null) files))]))
  (define ordered (reverse files))
  (define scenarios (append-map (lambda (file) (hash-ref file 'scenarios)) ordered))
  (define passed (count (lambda (item) (equal? (hash-ref item 'status) "passed")) scenarios))
  (define failed (- (length scenarios) passed))
  (define errors
    (append (filter hash? (map (lambda (file) (hash-ref file 'error)) ordered))
            (filter hash? (map (lambda (item) (hash-ref item 'error)) scenarios))))
  (define infra? (ormap (lambda (error) (equal? (hash-ref error 'code) "RUNTIME-BDD-INFRA")) errors))
  (define ok? (and (pair? scenarios) (zero? failed) (null? errors)))
  (hasheq 'ok (and ok? #t) 'passed passed 'failed failed 'not_executed 0 'file_errors (count (lambda (file) (hash? (hash-ref file 'error))) ordered)
          'files ordered 'exit_code (cond [ok? 0] [infra? 2] [else 1]))))

(define (make-bdd-service #:command [command (default-bdd-command)])
  (define (runtime-json value)
    (cond
      [(eq? value 'null) 'nil]
      [(hash? value) (for/hasheq ([(key item) (in-hash value)]) (values key (runtime-json item)))]
      [(list? value) (map runtime-json value)]
      [else value]))
  (lambda (name arguments span)
    (cond
      [(equal? name "BDD.run")
       (define report (run-bdd (list (car arguments)) #:steps (cadr arguments) #:command command))
       (if (= (hash-ref report 'exit_code) 2)
           (bdd-result #f "BDD infrastructure unavailable; use agentica test --json for details")
           (bdd-result #t (json-value (runtime-json report))))]
      [else (diagnostic 'RUNTIME-BDD-CONTEXT "BDD operation requires handler registration or a running scenario" span)])))

(define (format-bdd-report report #:ai? [ai? #f])
  (define lines
    (append-map
      (lambda (file)
        (append
          (if (hash? (hash-ref file 'error))
              (list (string-append "FAIL " (hash-ref file 'path) (if ai? " | " "\n")
                                   (jsexpr-diagnostic-summary (hash-ref file 'error)))) '())
          (for/list ([item (in-list (hash-ref file 'scenarios))])
            (string-append (if (equal? (hash-ref item 'status) "passed") "PASS " "FAIL ")
                           (hash-ref file 'feature) " / " (hash-ref item 'name)
                           (if (hash? (hash-ref item 'error))
                               (string-append (if ai? " | " "\n")
                                              (jsexpr-diagnostic-summary (hash-ref item 'error))) "")))))
      (hash-ref report 'files)))
  (string-join (append lines (list (format "~a passed, ~a failed, ~a not executed, ~a file errors"
                                          (hash-ref report 'passed) (hash-ref report 'failed)
                                          (hash-ref report 'not_executed) (hash-ref report 'file_errors)))) "\n"))

(define (jsexpr-diagnostic-summary error)
  (define position (hash-ref (hash-ref error 'range) 'start))
  (format "~a:~a:~a [~a] ~a~a~a"
          (hash-ref error 'file) (hash-ref position 'line) (hash-ref position 'column)
          (hash-ref error 'code) (hash-ref error 'message)
          (if (hash-has-key? error 'expected) (format "; expected ~s" (hash-ref error 'expected)) "")
          (if (hash-has-key? error 'actual) (format "; actual ~s" (hash-ref error 'actual)) "")))
