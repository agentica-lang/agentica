#lang racket

(provide opaque-types builtin-records)

(define opaque-types '(Socket Listener HttpClient FileHandle Process TestCase))

(define builtin-records
  (hash "Header" '(("name" . String) ("value" . String))
        "HttpResponse" '(("status" . Int) ("headers" . (List (Struct "Header"))) ("body" . String))
        "HttpClientOptions" '(("timeout_ms" . Int) ("idle_timeout_ms" . Int)
                              ("max_connections" . Int) ("max_body_bytes" . Int) ("ca_file" . String))
        "FileInfo" '(("kind" . String) ("size_bytes" . Int) ("modified_seconds" . Int))
        "ProcessOutput" '(("stdout" . String) ("stderr" . String) ("truncated" . Bool))))
