#lang racket/base

(require racket/runtime-path)

(provide run-main-in-process)

(define-runtime-path main-file "../src/main.rkt")

(for ([name (in-list '(#"LC_ALL" #"LANG"))])
  (environment-variables-set! (current-environment-variables) name #"C.UTF-8"))
(environment-variables-set! (current-environment-variables) #"LC_MESSAGES" #f)
(for ([name '(#"AGENTICA_VM_TRACE" #"AGENTICA_VM_TRACE_FILE")])
  (environment-variables-set! (current-environment-variables) name #f))

(define (run-main-in-process #:environment [environment (current-environment-variables)]
                             #:input [input #""]
                             #:port [port (open-input-bytes input)]
                             . arguments)
  (define out (open-output-string))
  (define err (open-output-string))
  (define custodian (make-custodian))
  (define status
    (dynamic-wind
      void
      (lambda ()
        (let/ec escape
          (parameterize ([current-custodian custodian]
                         [current-environment-variables environment]
                         [current-namespace (make-base-namespace)]
                         [current-command-line-arguments (list->vector arguments)]
                         [current-input-port port]
                         [current-output-port out]
                         [current-error-port err]
                         [exit-handler escape])
            (dynamic-require `(submod ,main-file main) #f)
            0)))
      (lambda () (custodian-shutdown-all custodian))))
  (list status (get-output-string out) (get-output-string err)))
