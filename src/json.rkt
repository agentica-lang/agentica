#lang racket

(require json)

(provide (struct-out json-value) read-json-value)

;; Opaque to Agentica; only JSON builtins read its contents.
(struct json-value (data))

(define (read-json-value text)
  ;; Racket's reader accepts raw control characters in strings; JSON forbids them.
  ;; This is only a string-boundary guard; read-json handles the JSON grammar.
  (for/fold ([quoted? #f] [escaped? #f]) ([ch (in-string text)])
    (when (and quoted? (< (char->integer ch) 32))
      (error 'JSON.parse "unescaped control character in a JSON string"))
    (cond
      [escaped? (values quoted? #f)]
      [(and quoted? (char=? ch #\\)) (values #t #t)]
      [(char=? ch #\") (values (not quoted?) #f)]
      [else (values quoted? #f)]))
  (define input (open-input-string text))
  ;; read-json can raise reader or contract errors; report one Agentica-level message.
  (define data
    (with-handlers ([exn:fail? (lambda (_) (error 'JSON.parse "invalid JSON"))])
      (read-json input #:null 'nil)))
  (when (eof-object? data)
    (error 'JSON.parse "expected a JSON value"))
  (for ([ch (in-port read-char input)])
    (unless (memv ch '(#\space #\tab #\return #\newline))
      (error 'JSON.parse "unexpected content after the JSON value")))
  (unless (jsexpr? data #:null 'nil)
    (error 'JSON.parse "JSON number is not finite"))
  (json-value data))
