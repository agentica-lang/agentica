#lang racket

(provide opaque-types handle-types builtin-records)

(define opaque-types '(Socket Listener HttpClient HttpServer FileHandle Process TestCase))

(define handle-types '(Socket Listener HttpServer FileHandle Process))

(define builtin-records
  (hash "Header" '(("name" . String) ("value" . String))
        "HttpRequest" '(("method" . String) ("target" . String) ("path" . String)
                        ("headers" . (List (Struct "Header"))) ("body" . String))
        "HttpResponse" '(("status" . Int) ("headers" . (List (Struct "Header"))) ("body" . String))
        "HttpClientOptions" '(("timeout_ms" . Int) ("idle_timeout_ms" . Int)
                              ("max_connections" . Int) ("max_body_bytes" . Int) ("ca_file" . String))
        "HttpServerOptions" '(("request_timeout_ms" . Int) ("idle_timeout_ms" . Int)
                              ("max_connections" . Int) ("max_body_bytes" . Int))
        "FileInfo" '(("kind" . String) ("size_bytes" . Int) ("modified_seconds" . Int))
        "ProcessOutput" '(("stdout" . String) ("stderr" . String) ("truncated" . Bool))))
