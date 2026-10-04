#lang racket

(require "network.rkt" "builtin-types.rkt" "runtime-values.rkt")

(provide (struct-out exn:http) (struct-out http-body) (struct-out http-writer)
         header-values connection-close? read-request-head read-response-head
         make-http-body body-read body-text body-close body-trailers
         make-http-writer writer-begin writer-write writer-finish writer-respond
         write-request-head http-call-wire)

(struct exn:http exn:fail (status) #:transparent)
(struct http-body (socket mode remaining total limit trailers done closed failure release) #:mutable)
(struct http-writer (socket mode remaining total limit started finished active suppress forbidden close) #:mutable)

(define (bad message [status 400])
  (raise (exn:http message (current-continuation-marks) status)))

(define token-pattern #px"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$")

(define (header-values headers name)
  (for/list ([header (in-list headers)]
             #:when (string-ci=? name (record-ref header "name")))
    (record-ref header "value")))

(define (connection-close? headers)
  (for/or ([value (in-list (header-values headers "connection"))])
    (member "close" (map string-downcase (map string-trim (string-split value ","))))))

(define (wire-line input [limit 8192])
  (define out (open-output-bytes))
  (let loop ([count 0])
    (define byte (read-byte input))
    (cond
      [(eof-object? byte) (bad "unexpected end of HTTP message")]
      [(= byte 13)
       (unless (equal? (read-byte input) 10) (bad "HTTP requires CRLF"))
       (bytes->string/latin-1 (get-output-bytes out))]
      [(= byte 10) (bad "HTTP requires CRLF")]
      [(>= count limit) (bad "HTTP line is too large" 431)]
      [else (write-byte byte out) (loop (add1 count))])))

(define (valid-header name value)
  (unless (and (regexp-match? token-pattern name)
               (for/and ([char (in-string value)])
                 (define code (char->integer char))
                 (or (= code 9) (and (>= code 32) (<= code 255) (not (= code 127))))))
    (bad "invalid HTTP header")))

(define forbidden-trailers '("content-length" "transfer-encoding" "host" "connection" "trailer"))

(define (read-headers input #:trailers? [trailers? #f])
  (let loop ([headers '()] [size 0])
    (define line (wire-line input))
    (define next (+ size (string-length line) 2))
    (when (> next 65536) (bad "HTTP headers are too large" 431))
    (cond
      [(string=? line "") (reverse headers)]
      [else
       (when (>= (length headers) 100) (bad "too many HTTP headers" 431))
       (define match (regexp-match #px"^([^:]+):(.*)$" line))
       (unless match (bad "invalid HTTP header"))
       (define name (string-downcase (cadr match)))
       (define value (string-trim (caddr match) #px"[\t ]+"))
       (valid-header name value)
       (when (and trailers? (member name forbidden-trailers)) (bad "forbidden trailer"))
       (loop (cons (record "Header" name value) headers) next)])))

(define (framing headers request?)
  (define lengths (append-map (lambda (v) (map string-trim (string-split v "," #:trim? #f)))
                             (header-values headers "content-length")))
  (define transfers (header-values headers "transfer-encoding"))
  (when (and (pair? lengths) (pair? transfers)) (bad "ambiguous HTTP body framing"))
  (cond
    [(pair? transfers)
     (unless (and (= (length transfers) 1) (string-ci=? (string-trim (car transfers)) "chunked"))
       (bad "unsupported transfer encoding" 501))
     (values 'chunked 0)]
    [(pair? lengths)
     (unless (and (andmap (lambda (s) (regexp-match? #px"^[0-9]+$" s)) lengths)
                  (andmap (lambda (s) (= (string->number s) (string->number (car lengths)))) lengths))
       (bad "invalid content length"))
     (values 'length (string->number (car lengths)))]
    [request? (values 'length 0)]
    [else (values 'eof 0)]))

(define (read-request-head socket timeout)
  (socket-operation socket 'read timeout
    (lambda ()
      (define input (net-socket-input socket))
      (if (eof-object? (peek-byte input)) #f
          (let ()
            (define match (regexp-match #px"^([^ ]+) ([^ ]+) HTTP/([0-9.]+)$" (wire-line input)))
            (unless match (bad "invalid request line"))
            (unless (string=? (list-ref match 3) "1.1") (bad "HTTP version is unsupported" 505))
            (define method (cadr match))
            (when (string=? method "CONNECT") (bad "CONNECT is unsupported" 501))
            (define target (caddr match))
            (unless (and (regexp-match? token-pattern method)
                         (or (string-prefix? target "/") (and (string=? method "OPTIONS") (string=? target "*")))
                         (for/and ([c (in-string target)]) (< 32 (char->integer c) 127)))
              (bad "invalid request target"))
            (define headers (read-headers input))
            (define hosts (header-values headers "host"))
            (unless (and (= (length hosts) 1) (not (string=? (car hosts) ""))) (bad "one Host header is required"))
            (define-values (mode body-length) (framing headers #t))
            (list method target headers mode body-length))))))

(define (read-response-head socket timeout)
  (socket-operation socket 'read timeout
    (lambda ()
      (define input (net-socket-input socket))
      (let loop ([count 0])
        (when (>= count 16) (bad "too many interim responses"))
        (define match (regexp-match #px"^HTTP/1\\.1 ([0-9]{3})(?: (.*))?$" (wire-line input)))
        (unless match (bad "invalid HTTP/1.1 response"))
        (define status (string->number (cadr match)))
        (unless (<= 100 status 599) (bad "invalid response status"))
        (define headers (read-headers input))
        (cond
          [(= status 101) (bad "protocol upgrades are unsupported")]
          [(< status 200) (loop (add1 count))]
          [else
           (define-values (mode length) (framing headers #f))
           (list status headers mode length)])))))

(define (make-http-body socket mode length limit [release void])
  (when (and (eq? mode 'length) (> length limit)) (bad "body exceeds configured limit" 413))
  (define body (http-body socket mode length 0 limit '() #f #f #f release))
  (when (and (eq? mode 'length) (zero? length)) (complete-body! body))
  body)

(define (complete-body! body)
  (unless (http-body-done body)
    (set-http-body-done! body #t)
    ((http-body-release body) #t)))

(define (body-close body)
  (check-owner (net-socket-owner (http-body-socket body)))
  (unless (or (http-body-closed body) (http-body-done body))
    (set-http-body-closed! body #t)
    (network-close (http-body-socket body))
    ((http-body-release body) #f))
  (void))

(define (body-read body count timeout)
  (check-owner (net-socket-owner (http-body-socket body)))
  (unless (exact-positive-integer? timeout) (error 'HTTP "timeout must be positive milliseconds"))
  (unless (and (exact-positive-integer? count) (<= count bytes-limit))
    (error 'HTTP "read size must be 1..1048576"))
  (define socket (http-body-socket body))
  (cond
    [(http-body-failure body) (raise (http-body-failure body))]
    [(http-body-closed body) (error 'HTTP "body is closed")]
    [(http-body-done body) '()]
    [else (with-handlers ([exn:fail? (lambda (e)
                                      (unless (and (exn:network-timeout? e) (not (exn:network-timeout-active? e)))
                                        (set-http-body-failure! body e)
                                        (body-close body))
                                      (raise e))])
           (socket-operation socket 'read timeout
    (lambda ()
      (when (http-body-failure body) (raise (http-body-failure body)))
      (when (http-body-closed body) (error 'HTTP "body is closed"))
      (with-handlers ([exn:fail? (lambda (failure)
                                 (set-http-body-failure! body failure)
                                 (body-close body)
                                 (raise failure))])
        (define input (net-socket-input socket))
        (cond
          [(http-body-done body) '()]
          [else
           (when (and (eq? (http-body-mode body) 'chunked) (zero? (http-body-remaining body)))
             (define line (wire-line input))
             (define match (regexp-match #px"^([0-9a-fA-F]+)(?:;[ -~]*)?$" line))
             (unless match (bad "invalid chunk size"))
             (define size (string->number (cadr match) 16))
             (when (> (+ (http-body-total body) size) (http-body-limit body))
               (bad "body exceeds configured limit" 413))
             (set-http-body-remaining! body size)
             (when (zero? size)
               (set-http-body-trailers! body (read-headers input #:trailers? #t))
               (complete-body! body)))
           (cond
             [(or (http-body-done body)
                  (and (eq? (http-body-mode body) 'length) (zero? (http-body-remaining body))))
              (complete-body! body) '()]
             [else
              (define max-count
                (if (eq? (http-body-mode body) 'eof) count (min count (http-body-remaining body))))
              (define buffer (make-bytes max-count))
              (define got (read-bytes-avail! buffer input))
              (cond
                [(eof-object? got)
                 (unless (eq? (http-body-mode body) 'eof) (bad "truncated HTTP body"))
                 (complete-body! body) '()]
                [else
                 (set-http-body-total! body (+ (http-body-total body) got))
                 (when (> (http-body-total body) (http-body-limit body)) (bad "body exceeds configured limit" 413))
                 (unless (eq? (http-body-mode body) 'eof)
                   (set-http-body-remaining! body (- (http-body-remaining body) got)))
                 (when (zero? (http-body-remaining body))
                   (case (http-body-mode body)
                     [(chunked) (unless (string=? (wire-line input 0) "") (bad "invalid chunk terminator"))]
                     [(length) (complete-body! body)]))
                 (bytes->list (subbytes buffer 0 got))])])])))))]))

(define (body-text body timeout)
  (network-timed timeout
    (lambda ()
      (define out (open-output-bytes))
      (let loop ([total 0])
        (define chunk (body-read body 65536 timeout))
        (cond
          [(null? chunk) (bytes->string/utf-8 (get-output-bytes out) #f)]
          [(> (+ total (length chunk)) bytes-limit) (body-close body) (error 'HTTP "text exceeds 1048576 bytes")]
          [else (write-bytes (list->bytes chunk) out) (loop (+ total (length chunk)))])))
    #:abort (lambda () (body-close body))))

(define (body-trailers body)
  (check-owner (net-socket-owner (http-body-socket body)))
  (unless (http-body-done body) (error 'HTTP "trailers require complete body consumption"))
  (http-body-trailers body))

(define (validate-headers headers #:trailers? [trailers? #f] #:managed? [managed? #f])
  (when (> (length headers) 100) (bad "too many headers"))
  (define size 0)
  (for ([header (in-list headers)])
    (define name (record-ref header "name"))
    (define value (record-ref header "value"))
    (valid-header name value)
    (when (and (not managed?) (member (string-downcase name)
                  (if trailers? forbidden-trailers '("content-length" "transfer-encoding"))))
      (bad "framing headers are managed by HTTP"))
    (define line-size (+ (string-length name) (string-length value) 4))
    (when (> line-size 8192) (bad "header line is too large"))
    (set! size (+ size line-size)))
  (when (> size 65536) (bad "headers are too large")))

(define (emit-headers output headers)
  (for ([header (in-list headers)])
    (write-bytes (string->bytes/latin-1
                  (string-append (record-ref header "name") ": " (record-ref header "value") "\r\n")) output)))

(define (framing-header length)
  (if (= length -1) (record "Header" "Transfer-Encoding" "chunked")
      (record "Header" "Content-Length" (number->string length))))

(define (http-date)
  (define date (seconds->date (current-seconds) #f))
  (define (pad value) (~r value #:min-width 2 #:pad-string "0"))
  (format "~a, ~a ~a ~a ~a:~a:~a GMT"
          (list-ref '("Sun" "Mon" "Tue" "Wed" "Thu" "Fri" "Sat") (date-week-day date))
          (pad (date-day date))
          (list-ref '("Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec") (sub1 (date-month date)))
          (date-year date) (pad (date-hour date)) (pad (date-minute date)) (pad (date-second date))))

(define (make-http-writer socket limit #:suppress? [suppress? #f])
  (http-writer socket #f 0 0 limit #f #f #t suppress? #f #f))

(define (writer-guard writer)
  (unless (http-writer-active writer) (error 'HTTP "writer is no longer active"))
  (when (http-writer-finished writer) (error 'HTTP "writer is finished")))

(define (writer-begin writer status headers length timeout)
  (unless (and (exact-integer? status) (<= 200 status 599)) (bad "response status must be 200..599"))
  (unless (and (exact-integer? length) (>= length -1) (<= length (http-writer-limit writer)))
    (bad "invalid body length"))
  (validate-headers headers)
  (define forbidden? (memv status '(204 304)))
  (define dated-headers (if (null? (header-values headers "date"))
                            (cons (record "Header" "Date" (http-date)) headers) headers))
  (define final-headers (if forbidden? dated-headers (cons (framing-header length) dated-headers)))
  (validate-headers final-headers #:managed? #t)
  (socket-operation (http-writer-socket writer) 'write timeout
    (lambda ()
      (writer-guard writer)
      (when (http-writer-started writer) (error 'HTTP "response already started"))
      (set-http-writer-forbidden! writer forbidden?)
      (set-http-writer-mode! writer (if (= length -1) 'chunked 'length))
      (set-http-writer-remaining! writer length)
      (set-http-writer-started! writer #t)
      (set-http-writer-close! writer (and (connection-close? headers) #t))
      (define output (net-socket-output (http-writer-socket writer)))
      (display (format "HTTP/1.1 ~a Response\r\n" status) output)
      (emit-headers output final-headers)
      (display "\r\n" output)
      (flush-output output)
      (void))))

(define (write-request-head writer method target host headers length timeout)
  (when (string=? method "CONNECT") (bad "CONNECT is unsupported" 501))
  (unless (and (regexp-match? token-pattern method)
               (for/and ([char (in-string target)]) (< 32 (char->integer char) 127)))
    (bad "invalid method or request target"))
  (validate-headers headers)
  (when (pair? (header-values headers "host")) (bad "Host is managed by HTTP"))
  (unless (and (>= length -1) (<= length (http-writer-limit writer))) (bad "invalid body length"))
  (define final-headers (cons (record "Header" "Host" host) (cons (framing-header length) headers)))
  (validate-headers final-headers #:managed? #t)
  (socket-operation (http-writer-socket writer) 'write timeout
    (lambda ()
      (define output (net-socket-output (http-writer-socket writer)))
      (display (format "~a ~a HTTP/1.1\r\n" method target) output)
      (emit-headers output final-headers)
      (display "\r\n" output)
      (flush-output output)
      (set-http-writer-started! writer #t)
      (set-http-writer-mode! writer (if (= length -1) 'chunked 'length))
      (set-http-writer-remaining! writer length)
      (void))))

(define (writer-write writer data timeout)
  (define bytes (if (string? data) (string->bytes/utf-8 data) (valid-bytes data)))
  (when (> (bytes-length bytes) bytes-limit) (bad "write exceeds 1048576 bytes"))
  (socket-operation (http-writer-socket writer) 'write timeout
    (lambda ()
      (writer-guard writer)
      (unless (http-writer-started writer) (error 'HTTP "start the response before writing"))
      (when (and (http-writer-forbidden writer) (positive? (bytes-length bytes))) (bad "this response cannot have a body"))
      (define total (+ (http-writer-total writer) (bytes-length bytes)))
      (when (> total (http-writer-limit writer)) (bad "body exceeds configured limit" 413))
      (when (eq? (http-writer-mode writer) 'length)
        (when (> (bytes-length bytes) (http-writer-remaining writer)) (bad "body exceeds Content-Length"))
        (set-http-writer-remaining! writer (- (http-writer-remaining writer) (bytes-length bytes))))
      (set-http-writer-total! writer total)
      (unless (or (http-writer-suppress writer) (http-writer-forbidden writer) (zero? (bytes-length bytes)))
        (define output (net-socket-output (http-writer-socket writer)))
        (when (eq? (http-writer-mode writer) 'chunked)
          (display (string-append (number->string (bytes-length bytes) 16) "\r\n") output))
        (write-bytes bytes output)
        (when (eq? (http-writer-mode writer) 'chunked) (display "\r\n" output))
        (flush-output output))
      (void))))

(define (writer-finish writer trailers timeout)
  (validate-headers trailers #:trailers? #t)
  (socket-operation (http-writer-socket writer) 'write timeout
    (lambda ()
      (writer-guard writer)
      (unless (http-writer-started writer) (error 'HTTP "response is not started"))
      (unless (or (http-writer-suppress writer) (http-writer-forbidden writer))
        (case (http-writer-mode writer)
          [(length)
           (unless (and (zero? (http-writer-remaining writer)) (null? trailers))
             (bad "incomplete fixed-length body or invalid trailers"))]
          [(chunked)
           (define output (net-socket-output (http-writer-socket writer)))
           (display "0\r\n" output)
           (emit-headers output trailers)
           (display "\r\n" output)
           (flush-output output)]))
      (set-http-writer-finished! writer #t)
      (void))))

(define (writer-respond writer status headers text timeout)
  (define data (string->bytes/utf-8 text))
  (writer-begin writer status headers (bytes-length data) timeout)
  (unless (http-writer-forbidden writer) (writer-write writer text timeout))
  (writer-finish writer '() timeout))

(define (http-call-wire name args)
  (match name
    ["HTTP.close_body" (body-close (car args))]
    ["HTTP.header_values" (apply header-values args)]
    [else
     (network-result
      (lambda ()
        (match name
          ["HTTP.read" (apply body-read args)]
          ["HTTP.text" (apply body-text args)]
          ["HTTP.trailers" (apply body-trailers args)]
          ["HTTP.begin" (apply writer-begin args)]
          [(or "HTTP.write" "HTTP.write_bytes") (apply writer-write args)]
          ["HTTP.finish" (apply writer-finish args)]
          ["HTTP.respond" (apply writer-respond args)])))]))
