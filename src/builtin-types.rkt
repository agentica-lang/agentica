#lang racket

(provide opaque-types builtin-records builtin-field-order record record-ref)

(require "runtime-values.rkt")

(define opaque-types '(Socket Listener HttpClient HttpServer HttpBody HttpWriter FileHandle))

(define builtin-records
  (hash "Header" '(("name" . String) ("value" . String))
        "Request" '(("method" . String) ("target" . String) ("path" . String)
                    ("headers" . (List (Struct "Header"))) ("body" . HttpBody))
        "Response" '(("status" . Int) ("headers" . (List (Struct "Header"))) ("body" . HttpBody))
        "HttpClientOptions" '(("timeout_ms" . Int) ("idle_timeout_ms" . Int)
                              ("max_connections" . Int) ("max_body_bytes" . Int) ("ca_file" . String))
        "HttpServerOptions" '(("header_timeout_ms" . Int) ("idle_timeout_ms" . Int)
                              ("max_connections" . Int) ("max_body_bytes" . Int))
        "FileInfo" '(("kind" . String) ("size_bytes" . Int) ("modified_seconds" . Int))))

(define builtin-field-order
  (for/hash ([(name fields) (in-hash builtin-records)])
    (values name (map car fields))))

(define (record name . items)
  (instance name (for/hash ([field (in-list (hash-ref builtin-field-order name))]
                           [value (in-list items)])
                   (values field value))))

(define (record-ref value field)
  (hash-ref (instance-fields value) field))
