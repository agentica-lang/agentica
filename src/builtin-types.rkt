#lang racket

(provide opaque-types handle-types builtin-records builtin-enum-declarations builtin-enums
         list-type? map-type? set-type?)

;; The checker and the lowering both read a type as a list headed by its name
;; (`(List T)`, `(Map K V)`, `(Set T)`); the shape tests live here so they stay one copy.
(define (list-type? type)
  (and (pair? type) (eq? (car type) 'List)))

(define (map-type? type)
  (and (pair? type) (eq? (car type) 'Map)))

(define (set-type? type)
  (and (pair? type) (eq? (car type) 'Set)))

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
        "LogEvent" '(("level" . (Enum "LogLevel")) ("message" . String) ("fields" . (Map String String))
                     ("time_ms" . Int) ("task" . Int))
        "FileInfo" '(("kind" . String) ("size_bytes" . Int) ("modified_seconds" . Int))
        "ProcessOutput" '(("stdout" . String) ("stderr" . String) ("truncated" . Bool))))

(define builtin-enum-declarations
  '(("Await" ("T") ("Done" (TypeVar "T")) ("TimedOut"))
    ("LogLevel" () ("Debug") ("Info") ("Warning") ("Error"))))

(define builtin-enums
  (for/hash ([entry (in-list builtin-enum-declarations)])
    (values (car entry)
            (cons (cadr entry)
                  (for/hash ([variant (in-list (cddr entry))])
                    (values (car variant) (cdr variant)))))))
