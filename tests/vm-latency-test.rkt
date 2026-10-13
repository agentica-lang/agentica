#lang racket

(require rackunit
         racket/runtime-path)

(define-runtime-path root "..")
(define-runtime-path fixture "fixtures/latency/latency.agc")
(define-runtime-path close-fixture "fixtures/latency/close-reader.agc")
(define-runtime-path main-file "../src/main.rkt")

(define limit-ms 250)
(define wait-seconds 60)
(define vm-file (build-path root "dist" "agentica-vm"))

(for ([name '(#"AGENTICA_VM_TRACE" #"AGENTICA_VM_TRACE_FILE")])
  (environment-variables-set! (current-environment-variables) name #f))

(define (environment no-turn-cost?)
  (define env (environment-variables-copy (current-environment-variables)))
  (environment-variables-set! env #"AGENTICA_VM_TEST_NO_TURN_COST" (and no-turn-cost? #"1"))
  env)

(define (start bytecode mode no-turn-cost?)
  (parameterize ([current-environment-variables (environment no-turn-cost?)]
                 [current-subprocess-custodian-mode 'kill])
    (define-values (process out in err)
      (subprocess #f #f (current-error-port) vm-file "--" (path->string bytecode) mode))
    (values process out in)))

(define (next-line out)
  (define line (sync/timeout wait-seconds (read-line-evt out 'linefeed)))
  (unless line (error 'latency "no output from the VM within ~a s" wait-seconds))
  line)

(define (stop process out in)
  (when (eq? (subprocess-status process) 'running) (subprocess-kill process #t))
  (subprocess-wait process)
  (close-input-port out)
  (close-output-port in))

(define (concurrently . thunks)
  (define custodian (make-custodian))
  (dynamic-wind
    void
    (lambda ()
      (define workers
        (for/list ([thunk (in-list thunks)])
          (define outcome (box #f))
          (define worker
            (parameterize ([current-custodian custodian])
              (thread (lambda ()
                        (set-box! outcome (with-handlers ([exn:fail? (lambda (e) (cons 'raised e))])
                                            (cons 'returned (thunk))))))))
          (cons worker outcome)))
      (for/list ([worker (in-list workers)])
        (thread-wait (car worker))
        (define outcome (unbox (cdr worker)))
        (if (eq? (car outcome) 'raised) (raise (cdr outcome)) (cdr outcome))))
    (lambda () (custodian-shutdown-all custodian))))

(define (sleep-worst bytecode no-turn-cost?)
  (define-values (process out in) (start bytecode "sleep" no-turn-cost?))
  (dynamic-wind
    void
    (lambda ()
      (close-output-port in)
      (define line (next-line out))
      (match (and (string? line) (regexp-match #rx"^worst ([0-9]+)$" line))
        [(list _ worst) (string->number worst)]
        [_ (error 'latency "unexpected output: ~s" line)]))
    (lambda () (stop process out in))))

(define (echo-worst bytecode no-turn-cost?)
  (define-values (process out in) (start bytecode "echo" no-turn-cost?))
  (dynamic-wind
    void
    (lambda ()
      (let loop ([round 0] [worst 0])
        (cond
          [(or (= round 20) (> worst limit-ms)) worst]
          [else
           (unless (equal? (next-line out) "ready") (error 'latency "the program did not say ready"))
           (define sent (current-inexact-monotonic-milliseconds))
           (fprintf in "line ~a\n" round)
           (flush-output in)
           (define reply (next-line out))
           (define delay (- (current-inexact-monotonic-milliseconds) sent))
           (unless (equal? reply (format "echo line ~a" round)) (error 'latency "unexpected echo: ~s" reply))
           (loop (add1 round) (max worst delay))])))
    (lambda () (stop process out in))))

(module+ test
  (cond
    [(or (getenv "AGENTICA_VM") (getenv "AGENTICA_VM_BINARY"))
     (displayln "SKIP VM latency tests: AGENTICA_VM or AGENTICA_VM_BINARY names another binary")]
    [(not (parameterize ([current-directory root]) (system* (find-executable-path "make") "-s" "vm")))
     (if (getenv "AGENTICA_REQUIRE_VM")
         (error 'latency "the VM must build when AGENTICA_REQUIRE_VM is set")
         (displayln "SKIP VM latency tests: make vm failed"))]
    [else
     (define work (make-temporary-directory "agentica-latency~a"))
     (define bytecode (build-path work "latency.agcb"))
     (dynamic-wind
       void
       (lambda ()
         (check-true (system* (find-system-path 'exec-file) (path->string main-file)
                              "compile" (path->string fixture) "-o" (path->string bytecode)))
         (test-case "a sleeping task and a stdin reader wake on time next to CPU, sort and concat tasks"
           (define sleep (sleep-worst bytecode #f))
           (define echo (echo-worst bytecode #f))
           (printf "VM latency with turn costs: sleep wake ~a ms, stdin echo ~a ms (limit ~a ms)\n"
                   sleep (round echo) limit-ms)
           (check-true (< sleep limit-ms) (format "sleep wake ~a ms" sleep))
           (check-true (< echo limit-ms) (format "stdin echo ~a ms" echo)))
         (test-case "a task reading in a loop lets main close the handle, and the run ends"
           (define close-bytecode (build-path work "close-reader.agcb"))
           (check-true (system* (find-system-path 'exec-file) (path->string main-file)
                                "compile" (path->string close-fixture) "-o" (path->string close-bytecode)))
           (define-values (process out in err)
             (subprocess #f #f (current-error-port) vm-file "--" (path->string close-bytecode) (path->string work)))
           (dynamic-wind
             void
             (lambda ()
               (close-output-port in)
               (check-not-false (sync/timeout wait-seconds process) "the VM did not end")
               (check-equal? (subprocess-status process) 0)
               (check-equal? (port->string out) "ok()\ntrue\n"))
             (lambda () (stop process out in))))
         (test-case "without turn costs the same check fails"
           (define-values (sleep echo)
             (apply values (concurrently (lambda () (sleep-worst bytecode #t))
                                         (lambda () (echo-worst bytecode #t)))))
           (printf "VM latency without turn costs: sleep wake ~a ms, stdin echo ~a ms\n" sleep (round echo))
           (check-true (> sleep limit-ms) (format "sleep wake ~a ms" sleep))
           (check-true (> echo limit-ms) (format "stdin echo ~a ms" echo))))
       (lambda () (delete-directory/files work)))]))
