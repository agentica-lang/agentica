#lang racket

(require racket/file
         racket/match
         racket/path
         "runtime-values.rkt"
         "builtin-types.rkt"
         "network.rkt")

(provide (struct-out file-handle) current-file-owner current-file-shutdown
         current-file-handles current-file-registry-lock current-file-registry-closing filesystem-call
         filesystem-close-all!)

(struct file-handle (owner input output lock closed? custodian) #:mutable #:transparent)

(define current-file-owner (make-parameter #f))
(define current-file-shutdown (make-parameter custodian-shutdown-all))
(define current-file-handles (make-parameter #f))
(define current-file-registry-lock (make-parameter #f))
(define current-file-registry-closing (make-parameter #f))
(define bytes-limit 1048576)
(define close-wait-ms 1000)

(define (filesystem-result thunk)
  (with-handlers ([exn:network-timeout? (lambda (_failure) (result-error "filesystem: operation timed out"))]
                  [exn:fail? (lambda (failure) (result-error (exn-message failure)))])
    (result-ok (thunk))))

(define (check-owner handle)
  (unless (eq? (file-handle-owner handle) (current-file-owner))
    (error 'filesystem "file handle belongs to another execution")))

(define (require-input handle)
  (unless (file-handle-input handle)
    (error 'filesystem "file handle is not open for reading")))

(define (require-output handle)
  (unless (file-handle-output handle)
    (error 'filesystem "file handle is not open for writing")))

(define (close-handle handle)
  (unless (file-handle-closed? handle)
    (set-file-handle-closed?! handle #t)
    ((current-file-shutdown) (file-handle-custodian handle))
    (for ([port (in-list (filter values (list (file-handle-input handle)
                                               (file-handle-output handle))))])
      (with-handlers ([exn:fail? void])
        (if (input-port? port) (close-input-port port) (close-output-port port)))))
  (void))

(define (timed-handle-operation handle timeout thunk #:close-on-timeout? [close-on-timeout? #t]
                               #:allow-closed? [allow-closed? #f])
  (check-owner handle)
  (define active? (box #f))
  (network-timed timeout
    (lambda ()
      (call-with-semaphore
       (file-handle-lock handle)
       (lambda ()
         (when (and (file-handle-closed? handle) (not allow-closed?))
           (error 'filesystem "file handle is closed"))
         (set-box! active? #t)
         (thunk))))
    #:abort (lambda ()
              (when (and close-on-timeout? (unbox active?))
                (close-handle handle)))))

(define (resolve-link-target path)
  (define absolute (path->complete-path path))
  (path->complete-path (resolve-path absolute) (path-only absolute)))

(define (effective-kind path)
  (let loop ([target path] [seen (list (path->complete-path path))])
    (define kind (file-or-directory-type target #f))
    (cond
      [(not (member kind '(link directory-link))) kind]
      [else
       (define next (resolve-link-target target))
       (if (member next seen)
           kind
           (loop next (cons next seen)))])))

(define (regular-file? path)
  (eq? (effective-kind path) 'file))

(define (validate-existing-file path)
  (unless (regular-file? path)
    (error 'filesystem "path does not refer to a regular file")))

(define (validate-write-target path)
  (define kind (effective-kind path))
  (when (and kind (not (eq? kind 'file)))
    (error 'filesystem "path does not refer to a regular file")))

(define (open-handle path mode timeout)
  (define custodian-box (box #f))
  (network-timed timeout
    (lambda ()
      (define custodian (make-custodian (current-custodian)))
      (set-box! custodian-box custodian)
      (with-handlers ([exn:fail? (lambda (failure)
                                   (custodian-shutdown-all custodian)
                                   (raise failure))])
        (define input #f)
        (define output #f)
        (cond
          [(string=? mode "read")
           (validate-existing-file path)
           (parameterize ([current-custodian custodian])
             (set! input (open-input-file path #:mode 'binary)))]
          [(member mode '("write" "append"))
           (validate-write-target path)
           (parameterize ([current-custodian custodian])
             (set! output (open-output-file path #:mode 'binary
                                            #:exists (if (string=? mode "write") 'truncate 'append))))]
          [else (error 'filesystem "mode must be read, write, or append")])
        (file-handle (current-file-owner) input output (make-semaphore 1) #f custodian)))
    #:abort (lambda ()
              (define custodian (unbox custodian-box))
              (when custodian (custodian-shutdown-all custodian)))))

(define (register-handle handle)
  (define handles (current-file-handles))
  (when handles
    (call-with-semaphore
     (current-file-registry-lock)
     (lambda ()
       (when (unbox (current-file-registry-closing))
         (close-handle handle)
         (error 'filesystem "execution is closing"))
       (hash-set! handles handle #t)))))

(define (filesystem-close-all! handles lock closing?)
  (call-with-semaphore
   lock
   (lambda ()
     (set-box! closing? #t)
     (for ([handle (in-list (hash-keys handles))])
       ;; Give a task that is mid-operation a bounded chance to release the
       ;; handle lock so its buffered output is flushed before the port closes.
       (when (sync/timeout (/ close-wait-ms 1000) (file-handle-lock handle))
         (dynamic-wind
           void
           (lambda ()
             (unless (file-handle-closed? handle)
               (with-handlers ([exn:fail? void])
                 (when (file-handle-output handle) (flush-output (file-handle-output handle))))
               (close-handle handle)))
           (lambda () (semaphore-post (file-handle-lock handle)))))))))

(define (read-line-bytes port)
  (define out (open-output-bytes))
  (let loop ([count 0])
    (define byte (read-byte port))
    (cond
      [(eof-object? byte)
       (if (zero? count) eof (get-output-bytes out))]
      [(= byte 10)
       (define line (get-output-bytes out))
       (if (and (positive? (bytes-length line))
                (= (bytes-ref line (sub1 (bytes-length line))) 13))
           (subbytes line 0 (sub1 (bytes-length line)))
           line)]
      [(>= count bytes-limit) (error 'filesystem "line exceeds 1048576 bytes")]
      [else (write-byte byte out) (loop (add1 count))])))

(define (read-whole path timeout)
  (network-timed timeout
    (lambda ()
      (validate-existing-file path)
      (define size (file-size path))
      (when (> size bytes-limit) (error 'filesystem "file exceeds 1048576 bytes"))
      (define bytes (call-with-input-file path (lambda (port) (read-bytes (+ size 1) port)) #:mode 'binary))
      (cond
        [(eof-object? bytes) ""]
        [(> (bytes-length bytes) bytes-limit) (error 'filesystem "file exceeds 1048576 bytes")]
        [else (bytes->string/utf-8 bytes #f)]))))

(define (write-whole path text append? timeout)
  (define bytes (string->bytes/utf-8 text))
  (when (> (bytes-length bytes) bytes-limit)
    (error 'filesystem "text exceeds 1048576 bytes"))
  (network-timed timeout
    (lambda ()
      (validate-write-target path)
      (call-with-output-file path (lambda (port) (write-bytes bytes port))
        #:mode 'binary #:exists (if append? 'append 'truncate))
      (void))))

(define (stat-path path timeout)
  (network-timed timeout
    (lambda ()
      (define kind (effective-kind path))
      (unless kind (error 'filesystem "path does not exist"))
      (unless (member kind '(file directory))
        (error 'filesystem "path is not a regular file or directory"))
      (define stats (file-or-directory-stat path))
      (record "FileInfo" (symbol->string kind)
              (if (eq? kind 'file) (hash-ref stats 'size) 0)
              (hash-ref stats 'modify-time-seconds)))))

(define (filesystem-call name args)
  (define (res thunk) (filesystem-result thunk))
  (case (string->symbol name)
    [(File.open)
     (res (lambda ()
            (define handle (apply open-handle args))
            (register-handle handle)
            handle))]
    [(File.read_bytes)
     (match-define (list handle max-bytes timeout) args)
     (res (lambda ()
            (unless (and (exact-positive-integer? max-bytes) (<= max-bytes bytes-limit))
              (error 'filesystem "max_bytes must be between 1 and 1048576"))
            (timed-handle-operation handle timeout
              (lambda ()
                (require-input handle)
                (define bytes (read-bytes max-bytes (file-handle-input handle)))
                (if (eof-object? bytes) '() (bytes->list bytes))))))]
    [(File.read_line)
     (match-define (list handle timeout) args)
     (res (lambda ()
            (define bytes (timed-handle-operation handle timeout
                            (lambda ()
                              (require-input handle)
                              (read-line-bytes (file-handle-input handle)))))
            (when (eof-object? bytes) (error 'filesystem "end of file"))
            (bytes->string/utf-8 bytes #f)))]
    [(File.write)
     (match-define (list handle text timeout) args)
     (res (lambda ()
            (define bytes (string->bytes/utf-8 text))
            (when (> (bytes-length bytes) bytes-limit) (error 'filesystem "text exceeds 1048576 bytes"))
            (timed-handle-operation handle timeout
              (lambda ()
                (require-output handle)
                (write-bytes bytes (file-handle-output handle)) (void)))))]
    [(File.write_bytes)
     (match-define (list handle values timeout) args)
     (res (lambda ()
            (define bytes (valid-bytes values))
            (timed-handle-operation handle timeout
              (lambda ()
                (require-output handle)
                (write-bytes bytes (file-handle-output handle)) (void)))))]
    [(File.flush)
     (match-define (list handle timeout) args)
     (res (lambda ()
            (timed-handle-operation handle timeout
              (lambda ()
                (require-output handle)
                (flush-output (file-handle-output handle)) (void)))))]
    [(File.close)
     (define handle (car args))
     (res (lambda ()
            (check-owner handle)
            (timed-handle-operation handle (cadr args)
              (lambda ()
                (unless (file-handle-closed? handle)
                  (when (file-handle-output handle) (flush-output (file-handle-output handle)))
                  (close-handle handle))
                (void))
              #:allow-closed? #t)))]
    [(File.read_text) (res (lambda () (read-whole (car args) (cadr args))))]
    [(File.write_text) (res (lambda () (write-whole (car args) (cadr args) #f (caddr args))))]
    [(File.append_text) (res (lambda () (write-whole (car args) (cadr args) #t (caddr args))))]
    [(File.stat) (res (lambda () (stat-path (car args) (cadr args))))]
    [(Dir.list)
     (res (lambda () (network-timed (cadr args)
              (lambda () (sort (map path->string (directory-list (car args))) string<?)))))]
    [(Dir.mkdir)
     (res (lambda () (network-timed (cadr args)
              (lambda () (make-directory* (car args)) (void)))))]
    [(Path.cwd) (res (lambda () (path->string (current-directory))))]
    [(Path.join)
     (res (lambda ()
            (when (null? (car args)) (error 'filesystem "Path.join needs at least one part"))
            (path->string (apply build-path (car args)))))]
    [(Path.resolve)
     (res (lambda () (path->string (simplify-path (path->complete-path (car args)) #f))))]
    [else (error 'filesystem "unknown filesystem builtin")]))
