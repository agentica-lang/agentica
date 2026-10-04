#lang racket

(require "diagnostic.rkt" "runtime-values.rkt")

(provide task-run task-spawn task-await task-value? task-step! task-done-evt task-shutdown!)

(struct execution (custodian lock tasks steps limit finished outcome) #:mutable)
(struct task-value (owner ready outcome worker))

(define (publish! run value)
  (unless (unbox (execution-outcome run))
    (set-box! (execution-outcome run) (box value))
    (semaphore-post (execution-finished run))))

(define (protect thunk span)
  (with-handlers ([exn:fail? (lambda (failure)
                             (diagnostic 'RUNTIME-INTERNAL (exn-message failure) span))])
    (thunk)))

(define (task-run thunk limit span #:require-complete? [strict? #f] #:cleanup [cleanup void])
  (cond
    [(not (or (not limit) (exact-positive-integer? limit)))
     (diagnostic 'RUNTIME-INTERNAL "max-steps must be a positive integer or #f" span)]
    [else
     (define run (execution (make-custodian) (make-semaphore 1) '() 0 limit
                            (make-semaphore 0) (box #f)))
     (define supervisor (current-thread))
     (define cleaned (make-semaphore 0))
     (define cleanup-request (make-semaphore 0))
     (dynamic-wind void
       (lambda ()
         (thread
          (lambda ()
            (sync (thread-dead-evt supervisor) (semaphore-peek-evt cleanup-request))
            (with-handlers ([exn:fail? void]) (cleanup))
            (custodian-shutdown-all (execution-custodian run))
            (semaphore-post cleaned)))
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
         (semaphore-post cleanup-request)
         (sync (semaphore-peek-evt cleaned))))]))

(define (cancelled! run task span)
  (unless (unbox (task-value-outcome task))
    (set-box! (task-value-outcome task)
              (box (diagnostic 'RUNTIME-TASK-CANCELLED "task was cancelled" span)))
    (set-execution-tasks! run (remq task (execution-tasks run)))
    (semaphore-post (task-value-ready task))))

(define (task-done-evt task) (semaphore-peek-evt (task-value-ready task)))

(define (task-shutdown! run custodian)
  (custodian-shutdown-all custodian)
  (call-with-semaphore (execution-lock run)
    (lambda ()
      (for ([task (in-list (execution-tasks run))])
        (define worker (unbox (task-value-worker task)))
        (when (and worker (thread-dead? (car worker)))
          (cancelled! run task (cdr worker)))))))

(define (task-spawn run thunk span #:custodian [custodian (current-custodian)])
  (define task (task-value run (make-semaphore 0) (box #f) (box #f)))
  (call-with-semaphore (execution-lock run)
    (lambda () (set-execution-tasks! run (cons task (execution-tasks run)))))
  (define worker
    (with-handlers ([exn:fail? (lambda (e)
                               (call-with-semaphore (execution-lock run)
                                 (lambda () (cancelled! run task span)))
                               (raise e))])
     (parameterize ([current-custodian custodian])
      (thread
     (lambda ()
       (define value (protect thunk span))
       (call-with-semaphore (execution-lock run)
         (lambda ()
           (set-box! (task-value-outcome task) (box value))
           (set-execution-tasks! run (remq task (execution-tasks run)))
           (when (or (diagnostic? value) (exit-code? value)) (publish! run value))
           (semaphore-post (task-value-ready task)))))))))
  (set-box! (task-value-worker task) (cons worker span))
  (parameterize ([current-custodian (execution-custodian run)])
    (thread
     (lambda ()
       (sync (thread-dead-evt worker))
       (call-with-semaphore (execution-lock run)
         (lambda ()
           (cancelled! run task span))))))
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
