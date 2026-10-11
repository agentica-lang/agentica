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

(define sigma #x3A3)
(define final-sigma #x3C2)
(define capital-a 65)
(define capital-b 66)

(define (chars->string ns) (list->string (map integer->char ns)))
(define (string->code-points text) (map char->integer (string->list text)))
(define (final-at? text index) (= (char->integer (string-ref text index)) final-sigma))
(define (ends-final? text) (final-at? text (sub1 (string-length text))))

(define (case-mapping convert)
  (for*/list ([n (in-list code-points)]
              [mapped (in-value (string->code-points (convert (string (integer->char n)))))]
              #:unless (equal? mapped (list n)))
    (cons n mapped)))

(define (model-upcase ns up)
  (append* (for/list ([n (in-list ns)]) (hash-ref up n (lambda () (list n))))))

(define (model-downcase ns down cased ignorable)
  (define v (list->vector ns))
  (define len (vector-length v))
  (define (cased-after? j)
    (cond
      [(= j len) #f]
      [(hash-ref cased (vector-ref v j) #f) #t]
      [(hash-ref ignorable (vector-ref v j) #f) (cased-after? (add1 j))]
      [else #f]))
  (let loop ([i 0] [before #f] [out '()])
    (cond
      [(= i len) (append* (reverse out))]
      [else
       (define n (vector-ref v i))
       (define mapped
         (if (and (= n sigma) before (not (cased-after? (add1 i))))
             (list final-sigma)
             (hash-ref down n (lambda () (list n)))))
       (loop (add1 i)
             (cond [(hash-ref cased n #f) #t] [(hash-ref ignorable n #f) before] [else #f])
             (cons mapped out))])))

(define (case-tables)
  (define up-list (case-mapping string-upcase))
  (define down-list (case-mapping string-downcase))
  (define up (for/hasheqv ([entry (in-list up-list)]) (values (car entry) (cdr entry))))
  (define down (for/hasheqv ([entry (in-list down-list)]) (values (car entry) (cdr entry))))
  (define cased-list
    (filter (lambda (n) (ends-final? (string-downcase (chars->string (list n sigma))))) code-points))
  (define cased (for/hasheqv ([n (in-list cased-list)]) (values n #t)))
  (define ignorable-list
    (filter (lambda (n)
              (and (not (hash-ref cased n #f))
                   (ends-final? (string-downcase (chars->string (list capital-a n sigma))))))
            code-points))
  (define ignorable (for/hasheqv ([n (in-list ignorable-list)]) (values n #t)))
  (define (check-case! ns)
    (define text (chars->string ns))
    (unless (equal? (string->code-points (string-upcase text)) (model-upcase ns up))
      (error 'gen-unicode "upcase of ~s is ~s, the C rule gives ~s"
             ns (string-upcase text) (chars->string (model-upcase ns up))))
    (unless (equal? (string->code-points (string-downcase text)) (model-downcase ns down cased ignorable))
      (error 'gen-unicode "downcase of ~s is ~s, the C rule gives ~s"
             ns (string-downcase text) (chars->string (model-downcase ns down cased ignorable)))))
  (for ([n (in-list code-points)])
    (check-case! (list n sigma))
    (check-case! (list capital-a n sigma))
    (check-case! (list capital-a sigma n))
    (check-case! (list capital-a sigma n capital-b))
    (check-case! (list 49 n sigma)))
  (for ([n (in-list ignorable-list)])
    (check-case! (list capital-a n n sigma))
    (check-case! (list capital-a sigma n n capital-b))
    (check-case! (list capital-a sigma n n))
    (check-case! (list sigma n sigma n)))
  (for ([n (in-list cased-list)])
    (check-case! (list n #x301 sigma #x301 32)))
  (check-case! code-points)
  (check-case! (reverse code-points))
  (values up-list down-list (ranges-of cased-list) (ranges-of ignorable-list)))

(define (c-case-table name entries)
  (string-append
   (format "const uint32_t ~a[][4] = {\n" name)
   (string-append*
    (for/list ([entry (in-list entries)])
      (define padded (append entry (make-list (- 4 (length entry)) 0)))
      (format "  {~a},\n" (string-join (map (lambda (n) (format "0x~a" (~r n #:base '(up 16)))) padded) ", "))))
   "};\n\n"
   (format "const size_t ~a_count = sizeof ~a / sizeof ~a[0];\n" name name name)))

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
  (define-values (up down cased ignorable) (case-tables))
  (string-append
   "#include \"agc.h\"\n\n"
   (c-table "agc_write_raw" raw)
   "\n"
   (c-table "agc_write_joiner" joiner)
   "\n"
   (c-table "agc_write_blank" blank)
   "\n"
   (c-case-table "agc_upcase_map" up)
   "\n"
   (c-case-table "agc_downcase_map" down)
   "\n"
   (c-table "agc_cased" cased)
   "\n"
   (c-table "agc_case_ignorable" ignorable)))

(module+ main
  (define arguments (current-command-line-arguments))
  (cond
    [(= (vector-length arguments) 1)
     (define text (unicode-data-text))
     (call-with-output-file (vector-ref arguments 0) #:exists 'truncate
       (lambda (out) (void (write-string text out))))]
    [else (void (write-string (unicode-data-text)))]))
