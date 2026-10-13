#lang racket

(provide opaque-types builtin-records builtin-field-order record record-ref)

(require "runtime-values.rkt")

(define opaque-types '(Socket Listener HttpClient FileHandle Process))

(define builtin-records
  (hash "Header" '(("name" . String) ("value" . String))
        "HttpResponse" '(("status" . Int) ("headers" . (List (Struct "Header"))) ("body" . String))
        "HttpClientOptions" '(("timeout_ms" . Int) ("idle_timeout_ms" . Int)
                              ("max_connections" . Int) ("max_body_bytes" . Int) ("ca_file" . String))
        "FileInfo" '(("kind" . String) ("size_bytes" . Int) ("modified_seconds" . Int))
        "ProcessOutput" '(("stdout" . String) ("stderr" . String) ("truncated" . Bool))))

(define builtin-field-order
  (for/hash ([(name fields) (in-hash builtin-records)])
    (values name (map car fields))))

(define (record name . items)
  (instance name (for/hash ([field (in-list (hash-ref builtin-field-order name))]
                           [value (in-list items)])
                   (values field value))))

(define (record-ref value field)
  (hash-ref (instance-fields value) field))
