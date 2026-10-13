#lang racket

(require (only-in ffi/unsafe -> _fun _int get-ffi-obj))

(provide find-vm stop-vm call-noting-break running-executable)

(define vm-name (if (eq? (system-type) 'windows) "agentica-vm.exe" "agentica-vm"))

(define (running-executable)
  (define run (find-system-path 'run-file))
  (normalize-path (or (find-executable-path run) run)))

(define (find-vm)
  (define override (getenv "AGENTICA_VM"))
  (define here (variable-reference->module-source (#%variable-reference)))
  (cond
    [(and override (not (equal? override ""))) (path->complete-path override)]
    [(path? here)
     (define-values (directory _name _dir?) (split-path here))
     (simplify-path (build-path directory 'up "dist" vm-name) #f)]
    [else (build-path (path-only (running-executable)) vm-name)]))

(define unix-kill (get-ffi-obj "kill" #f (_fun _int _int -> _int) (lambda () #f)))
(define sigterm 15)
(define vm-grace-seconds 2)

(define (stop-vm process #:interrupted? [interrupted? #f])
  (when (eq? (subprocess-status process) 'running)
    (unless (and interrupted? (sync/timeout vm-grace-seconds process))
      (when unix-kill (unix-kill (subprocess-pid process) sigterm))
      (unless (and unix-kill (sync/timeout vm-grace-seconds process))
        (subprocess-kill process #t)))))

(define (call-noting-break broke! thunk)
  (with-handlers* ([exn:break? (lambda (e) (broke!) (raise e))])
    (thunk)))
