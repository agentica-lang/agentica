#lang racket/base

(require racket/format racket/list racket/string)

(provide unicode-data-text)

(define short-escapes
  (hasheqv 7 "\\a" 8 "\\b" 9 "\\t" 10 "\\n" 11 "\\v" 12 "\\f" 13 "\\r" 27 "\\e" 34 "\\\"" 92 "\\\\"))

(define (code-point? n) (not (<= #xD800 n #xDFFF)))

(define (hex-escape n)
  (if (< n #x10000)
      (string-append "\\u" (~r n #:base '(up 16) #:min-width 4 #:pad-string "0"))
      (string-append "\\U" (~r n #:base '(up 16) #:min-width 8 #:pad-string "0"))))

(define (write-form n) (format "~s" (string (integer->char n))))

(define (raw? n)
  (define c (integer->char n))
  (define written (write-form n))
  (define raw (string #\" c #\"))
  (define escaped (string-append "\"" (hash-ref short-escapes n (lambda () (hex-escape n))) "\""))
  (cond
    [(and (not (hash-has-key? short-escapes n)) (string=? written raw)) #t]
    [(string=? written escaped) #f]
    [else (error 'gen-unicode "unexpected write form for U+~x: ~s" n written)]))

(define (raw-ranges)
  (define-values (ranges open)
    (for/fold ([ranges '()] [open #f]) ([n (in-range #x110000)] #:when (code-point? n))
      (cond
        [(raw? n) (if (and open (= (cdr open) (sub1 n))) (values ranges (cons (car open) n))
                      (values (if open (cons open ranges) ranges) (cons n n)))]
        [else (values (if open (cons open ranges) ranges) #f)])))
  (reverse (if open (cons open ranges) ranges)))

(define (check-whole-string!)
  (define all (for/list ([n (in-range #x110000)] #:when (code-point? n)) n))
  (define expected
    (string-append*
     (for/list ([n (in-list all)])
       (define text (write-form n))
       (substring text 1 (sub1 (string-length text))))))
  (unless (string=? (format "~s" (list->string (map integer->char all)))
                    (string-append "\"" expected "\""))
    (error 'gen-unicode "write form depends on neighboring characters")))

(define (unicode-data-text)
  (define ranges (raw-ranges))
  (check-whole-string!)
  (string-append
   "#include \"agc.h\"\n\n"
   "const uint32_t agc_write_raw_ranges[][2] = {\n"
   (string-append*
    (for/list ([range (in-list ranges)])
      (format "  {0x~a, 0x~a},\n" (~r (car range) #:base '(up 16)) (~r (cdr range) #:base '(up 16)))))
   "};\n\n"
   "const size_t agc_write_raw_count = sizeof agc_write_raw_ranges / sizeof agc_write_raw_ranges[0];\n"))

(module+ main
  (define arguments (current-command-line-arguments))
  (cond
    [(= (vector-length arguments) 1)
     (call-with-output-file (vector-ref arguments 0) #:exists 'truncate
       (lambda (out) (void (write-string (unicode-data-text) out))))]
    [else (void (write-string (unicode-data-text)))]))
