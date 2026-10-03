#lang racket

(require openssl "runtime-values.rkt")

(provide (struct-out net-socket) (struct-out net-listener) (struct-out exn:network-timeout) current-network-owner
         network-timed network-result network-connect network-listen network-accept
         network-upgrade network-close network-close-listener network-call current-network-shutdown
         socket-operation valid-bytes bytes-limit client-context check-owner)

(struct net-socket (owner input output read-lock write-lock closed custodian) #:mutable)
(struct net-listener (owner listener context port closed) #:mutable)
(struct exn:network-timeout exn:fail (active?) #:transparent)
(define current-network-owner (make-parameter #f))
(define current-network-shutdown (make-parameter custodian-shutdown-all))
(define bytes-limit 1048576)

(define (network-result thunk)
  (with-handlers ([exn:fail? (lambda (failure) (result-error (exn-message failure)))])
    (result-ok (thunk))))

(define (network-timed timeout thunk #:abort [abort void])
  (unless (exact-positive-integer? timeout) (error 'network "timeout must be positive milliseconds"))
  (define parent (current-custodian))
  (define cust (make-custodian parent))
  (define outcome (box #f))
  (define ready (make-semaphore 0))
  (dynamic-wind
    void
    (lambda ()
      (parameterize ([current-custodian cust])
        (thread (lambda ()
                  (define value
                    (with-handlers ([exn:fail? values])
                      (parameterize ([current-custodian parent]) (thunk))))
                  (set-box! outcome value)
                  (semaphore-post ready))))
      (unless (sync/timeout (/ timeout 1000) ready)
        (custodian-shutdown-all cust)
        (abort)
        (raise (exn:network-timeout "network: operation timed out" (current-continuation-marks) #t)))
      (define value (unbox outcome))
      (when (exn? value) (raise value))
      value)
    (lambda () (custodian-shutdown-all cust))))

(define (check-owner owner)
  (unless (eq? owner (current-network-owner))
    (error 'network "resource belongs to another execution")))

(define (network-close socket)
  (unless (net-socket-closed socket)
    (set-net-socket-closed! socket #t)
    (custodian-shutdown-all (net-socket-custodian socket))
    (for ([port (in-list (list (net-socket-input socket) (net-socket-output socket)))])
      (with-handlers ([exn:fail? void])
        (if (input-port? port) (close-input-port port) (close-output-port port)))))
  'nil)

(define (network-close-listener listener)
  (unless (net-listener-closed listener)
    (set-net-listener-closed! listener #t)
    (tcp-close (net-listener-listener listener)))
  'nil)

(define (make-socket input output cust)
  (net-socket (current-network-owner) input output (make-semaphore 1) (make-semaphore 1) #f cust))

(define (client-context ca-file)
  (if (string=? ca-file "")
      (ssl-secure-client-context)
      (parameterize ([ssl-default-verify-sources (list ca-file)])
        (ssl-secure-client-context))))

(define (network-connect host port timeout [ca-file #f])
  (define cust (make-custodian))
  (with-handlers ([exn:fail? (lambda (e) (custodian-shutdown-all cust) (raise e))])
   (network-timed timeout
    (lambda ()
      (define-values (input output)
        (parameterize ([current-custodian cust])
          (if ca-file (ssl-connect host port (client-context ca-file)) (tcp-connect host port))))
      (make-socket input output cust))
    #:abort (lambda () (custodian-shutdown-all cust)))))

(define (network-listen host port [cert #f] [key #f])
  (define ctx
    (and cert
         (let ([ctx (ssl-make-server-context 'secure)])
           (ssl-load-certificate-chain! ctx cert)
           (ssl-load-private-key! ctx key)
           ctx)))
  (define listener (tcp-listen port 128 #t host))
  (define-values (local-host local-port remote-host remote-port) (tcp-addresses listener #t))
  (net-listener (current-network-owner) listener ctx local-port #f))

(define (network-upgrade socket ctx timeout)
  (network-timed timeout
    (lambda ()
      (define-values (input output)
        (parameterize ([current-custodian (net-socket-custodian socket)])
          (ports->ssl-ports (net-socket-input socket) (net-socket-output socket)
                           #:mode 'accept #:context ctx #:close-original? #t)))
      (set-net-socket-input! socket input)
      (set-net-socket-output! socket output)
      socket)
    #:abort (lambda () (network-close socket))))

(define (network-accept listener timeout #:upgrade? [upgrade? #t])
  (check-owner (net-listener-owner listener))
  (when (net-listener-closed listener) (error 'network "listener is closed"))
  (define cust (make-custodian))
  (with-handlers ([exn:fail? (lambda (e) (custodian-shutdown-all cust) (raise e))])
   (network-timed timeout
    (lambda ()
      (define-values (input output)
        (parameterize ([current-custodian cust]) (tcp-accept (net-listener-listener listener))))
      (define socket (make-socket input output cust))
      (if (and upgrade? (net-listener-context listener))
          (network-upgrade socket (net-listener-context listener) timeout)
          socket))
    #:abort (lambda () (custodian-shutdown-all cust)))))

(define (socket-operation socket direction timeout thunk)
  (check-owner (net-socket-owner socket))
  (define entered? #f)
  (with-handlers ([exn:network-timeout? (lambda (e)
                                        (raise (exn:network-timeout (exn-message e)
                                                                   (exn-continuation-marks e) entered?)))])
   (network-timed timeout
    (lambda ()
      (call-with-semaphore
       (if (eq? direction 'read) (net-socket-read-lock socket) (net-socket-write-lock socket))
       (lambda ()
         (when (net-socket-closed socket) (error 'network "socket is closed"))
         (set! entered? #t)
         (thunk))))
    #:abort (lambda () (when entered? (network-close socket))))))

(define (valid-bytes values)
  (unless (and (<= (length values) bytes-limit) (andmap byte? values))
    (error 'network "bytes must be 0..255 and at most 1048576 per call"))
  (list->bytes values))

(define (network-call name args)
  (case (string->symbol name)
    [(TCP.close) (check-owner (net-socket-owner (car args))) (network-close (car args))]
    [(TCP.close_listener) (check-owner (net-listener-owner (car args))) (network-close-listener (car args))]
    [(TCP.local_port) (check-owner (net-listener-owner (car args))) (net-listener-port (car args))]
    [else
     (network-result
      (lambda ()
        (match name
          ["TCP.connect" (apply network-connect args)]
          ["TLS.connect" (match-define (list host port ca timeout) args) (network-connect host port timeout ca)]
          ["TCP.listen" (apply network-listen args)]
          ["TLS.listen" (apply network-listen args)]
          ["TCP.accept" (apply network-accept args)]
          [(or "TCP.send" "TCP.send_bytes")
           (match-define (list socket data timeout) args)
           (define bytes (if (string? data) (string->bytes/utf-8 data) (valid-bytes data)))
           (socket-operation socket 'write timeout
             (lambda () (write-bytes bytes (net-socket-output socket))
                        (flush-output (net-socket-output socket)) 'nil))]
          ["TCP.recv_bytes"
           (match-define (list socket count timeout) args)
           (unless (and (exact-positive-integer? count) (<= count bytes-limit))
             (error 'network "read size must be 1..1048576"))
           (socket-operation socket 'read timeout
             (lambda ()
               (define buffer (make-bytes count))
               (define got (read-bytes-avail! buffer (net-socket-input socket)))
               (if (eof-object? got) '() (bytes->list (subbytes buffer 0 got)))))]
          ["TCP.read_line"
           (match-define (list socket timeout) args)
           (socket-operation socket 'read timeout
             (lambda ()
               (define out (open-output-bytes))
               (let loop ([count 0])
                 (define byte (read-byte (net-socket-input socket)))
                 (cond
                   [(or (eof-object? byte) (= byte 10))
                    (when (and (eof-object? byte) (zero? count)) (error 'network "end of input"))
                    (define line (get-output-bytes out))
                    (bytes->string/utf-8
                     (if (and (equal? byte 10) (positive? count) (= (bytes-ref line (sub1 count)) 13))
                         (subbytes line 0 (sub1 count)) line) #f)]
                   [(>= count bytes-limit) (error 'network "line exceeds 1048576 bytes")]
                   [else (write-byte byte out) (loop (add1 count))]))))])))]))
