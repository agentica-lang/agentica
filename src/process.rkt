#lang racket

(require "runtime-values.rkt" "diagnostic.rkt" "network.rkt")

(provide process-call process-handle? process-close-all!
         current-process-owner current-process-registry current-process-registry-lock
         current-process-closing current-process-custodian current-process-allowed?)

(struct process-handle (owner registry registry-lock custodian process input output worker failure
                             read-lock write-lock state-lock closed? stdin-closed?) #:mutable)
(define current-process-owner (make-parameter #f))
(define current-process-registry (make-parameter #f))
(define current-process-registry-lock (make-parameter #f))
(define current-process-closing (make-parameter #f))
(define current-process-custodian (make-parameter #f))
(define current-process-allowed? (make-parameter #f))
(define bytes-limit 1048576)

(define (close-process p)
  (call-with-semaphore (process-handle-state-lock p)
    (lambda ()
      (unless (process-handle-closed? p)
        (set-process-handle-closed?! p #t)
        (define child (process-handle-process p))
        (custodian-shutdown-all (process-handle-custodian p))
        (when child
          (subprocess-kill child #t)
          (subprocess-wait child)))
      (call-with-semaphore (process-handle-registry-lock p)
        (lambda () (hash-remove! (process-handle-registry p) p)))))
  (void))

(define (process-close-all! registry lock closing)
  (define handles
    (call-with-semaphore lock
      (lambda () (set-box! closing #t) (hash-keys registry))))
  (for ([p (in-list handles)])
    (with-handlers ([exn:fail? void]) (close-process p))))

(define (process-result thunk)
  (with-handlers ([exn:fail? (lambda (failure) (result-error (exn-message failure)))])
    (result-ok (thunk))))

(define (require-open p)
  (when (process-handle-closed? p) (error 'process "process is closed"))
  (when (unbox (process-handle-failure p)) (raise (unbox (process-handle-failure p)))))

(define (spawn-process command arguments timeout)
  (unless (current-process-allowed?) (error 'process "spawning requires --allow-run"))
  (unless (and (positive? (string-length command))
               (andmap (lambda (s) (not (string-contains? s (string #\nul)))) (cons command arguments)))
    (error 'process "command must be nonempty and arguments cannot contain NUL"))
  (define p
    (process-handle (current-process-owner) (current-process-registry) (current-process-registry-lock)
                    (make-custodian (current-process-custodian))
                    #f #f #f #f (box #f) (make-semaphore 1) (make-semaphore 1)
                    (make-semaphore 1) #f #f))
  (call-with-semaphore (current-process-registry-lock)
    (lambda ()
      (when (unbox (current-process-closing)) (error 'process "execution is closing"))
      (hash-set! (current-process-registry) p #t)))
  (with-handlers ([exn:fail? (lambda (failure) (close-process p) (raise failure))])
    (network-timed timeout
      (lambda ()
        (define executable (find-executable-path command))
        (unless executable (error 'process "executable is unavailable"))
        (when (and (eq? (system-type) 'windows)
                   (member (path-get-extension executable) '(#".bat" #".cmd")))
          (error 'process "Windows batch commands are not supported"))
        (call-with-semaphore (process-handle-state-lock p)
          (lambda ()
            (require-open p)
            (define-values (child output input errors)
              (parameterize ([current-custodian (process-handle-custodian p)]
                             [current-subprocess-custodian-mode 'kill]
                             [current-subprocess-keep-file-descriptors '()])
                (apply subprocess #f #f #f executable arguments)))
            (set-process-handle-process! p child)
            (set-process-handle-input! p input)
            (set-process-handle-output! p output)
            (define destination (current-error-port))
            (set-process-handle-worker! p
              (parameterize ([current-custodian (process-handle-custodian p)])
                (thread
                  (lambda ()
                    (with-handlers ([exn:fail? (lambda (failure)
                                               (set-box! (process-handle-failure p) failure)
                                               (subprocess-kill child #t))])
                      (define buffer (make-bytes 4096))
                      (let loop ()
                        (define count (read-bytes-avail! buffer errors))
                        (unless (eof-object? count)
                          (write-bytes buffer destination 0 count)
                          (flush-output destination)
                          (loop))))))))
            p)))
      #:abort (lambda () (close-process p)))))

(define (stream-operation p direction timeout thunk)
  (define entered? #f)
  (network-timed timeout
    (lambda ()
      (call-with-semaphore
        (if (eq? direction 'read) (process-handle-read-lock p) (process-handle-write-lock p))
        (lambda () (require-open p) (set! entered? #t) (thunk))))
    #:abort (lambda () (when entered? (close-process p)))))

(define (read-line p)
  (define data (open-output-bytes))
  (let loop ([count 0])
    (define byte (read-byte (process-handle-output p)))
    (cond
      [(or (eof-object? byte) (= byte 10))
       (when (and (eof-object? byte) (zero? count)) (error 'process "end of input"))
       (define line (get-output-bytes data))
       (bytes->string/utf-8
         (if (and (equal? byte 10) (positive? count) (= (bytes-ref line (sub1 count)) 13))
             (subbytes line 0 (sub1 count)) line) #f)]
      [(>= count bytes-limit) (close-process p) (error 'process "line exceeds 1048576 bytes")]
      [else (write-byte byte data) (loop (add1 count))])))

(define (process-call name args span)
  (cond
    [(and (not (equal? name "Process.spawn"))
          (not (eq? (process-handle-owner (car args)) (current-process-owner))))
     (diagnostic 'RUNTIME-PROCESS-CONTEXT "process belongs to another execution" span)]
    [(equal? name "Process.close")
     (with-handlers ([exn:fail? (lambda (failure)
                                (diagnostic 'RUNTIME-PROCESS-CLOSE (exn-message failure) span))])
       (close-process (car args)))]
    [else
     (process-result
       (lambda ()
         (match name
           ["Process.spawn" (apply spawn-process args)]
           [(or "Process.send" "Process.send_bytes")
            (match-define (list p data timeout) args)
            (define bytes
              (if (string? data) (string->bytes/utf-8 data)
                  (begin
                    (unless (and (<= (length data) bytes-limit) (andmap byte? data))
                      (error 'process "bytes must be 0..255 and at most 1048576 per call"))
                    (list->bytes data))))
            (when (> (bytes-length bytes) bytes-limit) (error 'process "send exceeds 1048576 bytes"))
            (stream-operation p 'write timeout
              (lambda ()
                (when (process-handle-stdin-closed? p) (error 'process "stdin is closed"))
                (write-bytes bytes (process-handle-input p))
                (flush-output (process-handle-input p)) (void)))]
           ["Process.read_line"
            (match-define (list p timeout) args)
            (stream-operation p 'read timeout (lambda () (read-line p)))]
           ["Process.read_bytes"
            (match-define (list p count timeout) args)
            (unless (<= 0 count bytes-limit) (error 'process "count must be 0..1048576"))
            (stream-operation p 'read timeout
              (lambda ()
                (define data (if (zero? count) #"" (read-bytes count (process-handle-output p))))
                (if (eof-object? data) '() (bytes->list data))))]
           ["Process.close_stdin"
            (match-define (list p timeout) args)
            (stream-operation p 'write timeout
              (lambda ()
                (unless (process-handle-stdin-closed? p)
                  (close-output-port (process-handle-input p))
                  (set-process-handle-stdin-closed?! p #t)) (void)))]
           ["Process.wait"
            (match-define (list p timeout) args)
            (network-timed timeout
              (lambda ()
                (require-open p)
                (sync (process-handle-process p))
                (sync (thread-dead-evt (process-handle-worker p)))
                (require-open p)
                (subprocess-status (process-handle-process p))))])))]))
