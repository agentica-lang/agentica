#lang racket/base

(require racket/format racket/list racket/string)

(provide unicode-data-text)

(define short-escapes
  (hasheqv 7 "\\a" 8 "\\b" 9 "\\t" 10 "\\n" 11 "\\v" 12 "\\f" 13 "\\r" 27 "\\e" 34 "\\\"" 92 "\\\\"))

(define zwj #x200D)
(define tag-a #xE0041)

(define code-points
  (for/list ([n (in-range #x110000)] #:unless (<= #xD800 n #xDFFF)) n))

(define (hex-escape n)
  (if (< n #x10000)
      (string-append "\\u" (~r n #:base '(up 16) #:min-width 4 #:pad-string "0"))
      (string-append "\\U" (~r n #:base '(up 16) #:min-width 8 #:pad-string "0"))))

(define (escaped-form n) (hash-ref short-escapes n (lambda () (hex-escape n))))

(define (written ns) (format "~s" (list->string (map integer->char ns))))

(define (last-raw? ns)
  (define text (written ns))
  (define head (written (drop-right ns 1)))
  (define n (last ns))
  (define rest (and (string-prefix? text (substring head 0 (sub1 (string-length head))))
                    (substring text (sub1 (string-length head)) (sub1 (string-length text)))))
  (cond
    [(and rest (not (hash-has-key? short-escapes n)) (string=? rest (string (integer->char n)))) #t]
    [(and rest (string=? rest (escaped-form n))) #f]
    [else (error 'gen-unicode "unexpected write form of ~s: ~s" ns text)]))

(define (ranges-of members)
  (define-values (ranges open)
    (for/fold ([ranges '()] [open #f]) ([n (in-list members)])
      (if (and open (= (cdr open) (sub1 n)))
          (values ranges (cons (car open) n))
          (values (if open (cons open ranges) ranges) (cons n n)))))
  (reverse (if open (cons open ranges) ranges)))

(define (model ns raw joiner blank)
  (define-values (pieces join)
    (for/fold ([pieces '()] [join #f]) ([n (in-list ns)])
      (define plain? (and (not (hash-has-key? short-escapes n))
                          (or (hash-ref raw n #f) (and join (hash-ref joiner n #f)))))
      (values (cons (if plain? (string (integer->char n)) (escaped-form n)) pieces)
              (and plain? (not (hash-ref blank n #f))))))
  (string-append "\"" (string-append* (reverse pieces)) "\""))

(define (check! ns raw joiner blank)
  (unless (string=? (written ns) (model ns raw joiner blank))
    (error 'gen-unicode "write form of ~s is ~s, the C rule gives ~s"
           ns (written ns) (model ns raw joiner blank))))

(define (tables)
  (define raw-list (filter (lambda (n) (last-raw? (list n))) code-points))
  (define raw (for/hasheqv ([n (in-list raw-list)]) (values n #t)))
  (define joiner-list
    (filter (lambda (n) (and (not (hash-ref raw n #f)) (last-raw? (list (char->integer #\a) n))))
            code-points))
  (define joiner (for/hasheqv ([n (in-list joiner-list)]) (values n #t)))
  (define blank-list
    (filter (lambda (n) (and (hash-ref raw n #f) (not (last-raw? (list n zwj))))) code-points))
  (define blank (for/hasheqv ([n (in-list blank-list)]) (values n #t)))
  (for ([n (in-list code-points)])
    (check! (list (char->integer #\a) n) raw joiner blank)
    (check! (list n zwj) raw joiner blank)
    (check! (list n tag-a) raw joiner blank))
  (define prefixes
    (map (lambda (text) (map char->integer (string->list text)))
         '("" "a" " " "　" " " "\u0001" "\n" "̀" "\U0001F600" "a‍" " ‍"
           "" "​" "\U000E0041")))
  (for* ([prefix (in-list prefixes)] [j (in-list joiner-list)] [k (in-list joiner-list)])
    (check! (append prefix (list j k)) raw joiner blank)
    (check! (append prefix (list j (char->integer #\a) k)) raw joiner blank)
    (check! (append prefix (list j #x20 k)) raw joiner blank))
  (check! code-points raw joiner blank)
  (values (ranges-of raw-list) (ranges-of joiner-list) (ranges-of blank-list)))

(define (c-table name ranges)
  (string-append
   (format "const uint32_t ~a_ranges[][2] = {\n" name)
   (string-append*
    (for/list ([range (in-list ranges)])
      (format "  {0x~a, 0x~a},\n" (~r (car range) #:base '(up 16)) (~r (cdr range) #:base '(up 16)))))
   "};\n\n"
   (format "const size_t ~a_count = sizeof ~a_ranges / sizeof ~a_ranges[0];\n" name name name)))

(define (unicode-data-text)
  (define-values (raw joiner blank) (tables))
  (string-append
   "#include \"agc.h\"\n\n"
   (c-table "agc_write_raw" raw)
   "\n"
   (c-table "agc_write_joiner" joiner)
   "\n"
   (c-table "agc_write_blank" blank)))

(module+ main
  (define arguments (current-command-line-arguments))
  (cond
    [(= (vector-length arguments) 1)
     (call-with-output-file (vector-ref arguments 0) #:exists 'truncate
       (lambda (out) (void (write-string (unicode-data-text) out))))]
    [else (void (write-string (unicode-data-text)))]))
