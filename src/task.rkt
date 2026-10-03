#lang racket

(require "diagnostic.rkt" "runtime-values.rkt")

(provide task-run task-spawn task-await task-value? task-step!)

(struct execution (custodian lock tasks steps limit finished outcome) #:mutable)
(struct task-value (owner ready outcome))

(define (publish! run value)
  (unless (unbox (execution-outcome run))
    (set-box! (execution-outcome run) (box value))
    (semaphore-post (execution-finished run))))

(define (protect thunk span)
  (with-handlers ([exn:fail? (lambda (failure)
                             (diagnostic 'RUNTIME-INTERNAL (exn-message failure) span))])
    (thunk)))

(define (task-run thunk limit span #:require-complete? [strict? #f])
  (cond
    [(not (or (not limit) (exact-positive-integer? limit)))
     (diagnostic 'RUNTIME-INTERNAL "max-steps must be a positive integer or #f" span)]
    [else
     (define run (execution (make-custodian) (make-semaphore 1) '() 0 limit
                            (make-semaphore 0) (box #f)))
     (define supervisor (current-thread))
     (define cleaned (make-semaphore 0))
     (dynamic-wind void
       (lambda ()
         (thread
          (lambda ()
            (sync (thread-dead-evt supervisor) (semaphore-peek-evt cleaned))
            (custodian-shutdown-all (execution-custodian run))))
         (parameterize ([current-custodian (execution-custodian run)])
           (thread
            (lambda ()
              (define value (protect (lambda () (thunk run)) span))
              (call-with-semaphore (execution-lock run)
                (lambda ()
                  (publish! run
                    (if (and strict? (not (diagnostic? value)) (not (exit-code? value))
                             (ormap (lambda (task) (not (unbox (task-value-outcome task))))
                                    (execution-tasks run)))
                        (diagnostic 'RUNTIME-BDD-PENDING-TASKS
                                    "await pending tasks before returning from a BDD handler" span)
                        value)))))))
         (sync (semaphore-peek-evt (execution-finished run)))
         (unbox (unbox (execution-outcome run))))
       (lambda ()
         (custodian-shutdown-all (execution-custodian run))
         (semaphore-post cleaned)))]))

(define (task-spawn run thunk span)
  (define task (task-value run (make-semaphore 0) (box #f)))
  (call-with-semaphore (execution-lock run)
    (lambda () (set-execution-tasks! run (cons task (execution-tasks run)))))
  (parameterize ([current-custodian (execution-custodian run)])
    (thread
     (lambda ()
       (define value (protect thunk span))
       (call-with-semaphore (execution-lock run)
         (lambda ()
           (set-box! (task-value-outcome task) (box value))
           (set-execution-tasks! run (remq task (execution-tasks run)))
           (when (or (diagnostic? value) (exit-code? value)) (publish! run value))
           (semaphore-post (task-value-ready task)))))))
  task)

(define (task-await run task span)
  (cond
    [(not (eq? run (task-value-owner task)))
     (diagnostic 'RUNTIME-TASK-CONTEXT "task belongs to another execution" span)]
    [else
     (sync (semaphore-peek-evt (task-value-ready task)))
     (unbox (unbox (task-value-outcome task)))]))

(define (task-step! run span)
  (and (execution-limit run)
       (call-with-semaphore (execution-lock run)
         (lambda ()
           (cond
             [(>= (execution-steps run) (execution-limit run))
              (diagnostic 'RUNTIME-STEP-LIMIT "execution step budget exhausted" span)]
             [else
              (set-execution-steps! run (add1 (execution-steps run)))
              #f])))))
