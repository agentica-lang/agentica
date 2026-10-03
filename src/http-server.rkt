#lang racket

(require "network.rkt" "http-wire.rkt" "http-client.rkt" "builtin-types.rkt"
         "runtime-values.rkt" "diagnostic.rkt" "task.rkt")

(provide http-server? make-http-server close-http-server wait-http-server http-server-port)

(struct http-server (owner custodian listener stopped closed lock) #:mutable)

(define (http-server-port server)
  (check-owner (http-server-owner server))
  (net-listener-port (http-server-listener server)))

(define (close-http-server server)
  (check-owner (http-server-owner server))
  (call-with-semaphore (http-server-lock server)
    (lambda ()
      (unless (http-server-closed server)
        (set-http-server-closed! server #t)
        (network-close-listener (http-server-listener server))
        (semaphore-post (http-server-stopped server)))))
  ((current-network-shutdown) (http-server-custodian server))
  'nil)

(define (wait-http-server server)
  (check-owner (http-server-owner server))
  (sync (semaphore-peek-evt (http-server-stopped server)))
  'nil)

(define (make-http-server host port handler options invoke spawn [cert #f] [key #f])
  (validate-options options)
  (define cust (make-custodian))
  (with-handlers ([exn:fail? (lambda (e) (custodian-shutdown-all cust) (raise e))])
    (define listener
      (parameterize ([current-custodian cust]) (network-listen host port cert key)))
    (define server (http-server (current-network-owner) cust listener (make-semaphore 0) #f (make-semaphore 1)))
    (define slots (make-semaphore (record-ref options "max_connections")))
    (define timeout (record-ref options "header_timeout_ms"))
    (define idle (record-ref options "idle_timeout_ms"))
    (define limit (record-ref options "max_body_bytes"))
    (define (handle socket)
      (define active-writer #f)
      (with-handlers ([exn:fail? (lambda (e)
                                 (when (and (exn:http? e)
                                            (not (and active-writer (http-writer-started active-writer))))
                                   (with-handlers ([exn:fail? void])
                                     (writer-respond (make-http-writer socket limit) (exn:http-status e)
                                                     (list (record "Header" "Connection" "close")) "" timeout)))
                                 (network-close socket)
                                 'nil)])
        (when (net-listener-context listener)
          (network-upgrade socket (net-listener-context listener) timeout))
        (let loop ([first? #t])
          (set! active-writer #f)
          (define request-head
            (if first? (read-request-head socket timeout)
                (begin
                  (unless (sync/timeout (/ idle 1000) (net-socket-input socket))
                    (error 'HTTP "idle connection timed out"))
                  (read-request-head socket timeout))))
          (cond
            [(not request-head) 'nil]
            [else
             (match-define (list method target headers mode body-length) request-head)
             (when (pair? (header-values headers "upgrade"))
               (raise (exn:http "protocol upgrades are unsupported" (current-continuation-marks) 501)))
             (define body (make-http-body socket mode body-length limit))
             (define expectations (header-values headers "expect"))
             (when (pair? expectations)
               (unless (and (= (length expectations) 1) (string-ci=? (car expectations) "100-continue"))
                 (raise (exn:http "unsupported expectation" (current-continuation-marks) 417)))
               (socket-operation socket 'write timeout
                 (lambda () (display "HTTP/1.1 100 Continue\r\n\r\n" (net-socket-output socket))
                            (flush-output (net-socket-output socket)))))
             (define writer (make-http-writer socket limit #:suppress? (string=? method "HEAD")))
             (set! active-writer writer)
             (define request (record "Request" method target (car (string-split target "?" #:trim? #f)) headers body))
             (define result (invoke handler (list request writer)))
             (cond
               [(or (diagnostic? result) (exit-code? result)) result]
               [else
                (cond
                  [(not (http-writer-started writer))
                   (writer-respond writer 500 (list (record "Header" "Connection" "close")) "" timeout)
                   (network-close socket)]
                  [(not (http-writer-finished writer)) (writer-finish writer '() timeout)])
                (set-http-writer-active! writer #f)
                (when (and (eq? mode 'length) (zero? body-length)) (body-read body 1 timeout))
                (cond
                  [(or (net-socket-closed socket) (connection-close? headers) (http-writer-close writer)
                       (not (http-body-done body))) 'nil]
                  [else (loop #f)])])]))))
    (spawn
     (lambda ()
       (let loop ()
         (semaphore-wait slots)
         (sync (net-listener-listener listener))
         (define conn-cust (make-custodian cust))
         (define socket
           (parameterize ([current-custodian conn-cust]) (network-accept listener timeout #:upgrade? #f)))
         (define connection-task (spawn
          (lambda ()
            (dynamic-wind void (lambda () (handle socket))
                          (lambda () (network-close socket))))
          conn-cust))
         (parameterize ([current-custodian cust])
           (thread (lambda ()
                     (sync (task-done-evt connection-task))
                     ((current-network-shutdown) conn-cust)
                     (semaphore-post slots))))
         (loop)))
     cust)
    server))
