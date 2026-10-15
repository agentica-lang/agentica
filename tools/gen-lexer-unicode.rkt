#lang racket/base

(require racket/file
         racket/list
         racket/string
         racket/runtime-path)

(provide graphic-ranges
         unicode-source)

(define-runtime-path output "../compiler/unicode_table.agc")

(define (graphic? n)
  (define char (integer->char n))
  (and (char-graphic? char) (not (char-blank? char))))

(define (graphic-ranges)
  (define-values (ranges open)
    (for/fold ([ranges '()] [open #f]) ([n (in-range #x110000)])
      (cond
        [(<= #xD800 n #xDFFF) (values ranges open)]
        [(graphic? n)
         (if (and open (= (cdr open) (sub1 n)))
             (values ranges (cons (car open) n))
             (values (if open (cons open ranges) ranges) (cons n n)))]
        [else (values ranges open)])))
  (reverse (if open (cons open ranges) ranges)))

(define (rows numbers)
  (let loop ([rest numbers] [lines '()])
    (if (null? rest)
        (reverse lines)
        (let ([count (min 10 (length rest))])
          (loop (drop rest count)
                (cons (string-append "    " (string-join (map number->string (take rest count)) ", "))
                      lines))))))

(define (unicode-source)
  (define numbers (append-map (lambda (range) (list (car range) (cdr range))) (graphic-ranges)))
  (string-append
   "export def graphic_ranges() -> List[Int]\n"
   "  return [\n"
   (string-join (rows numbers) ",\n")
   "\n  ]\n"
   "end\n"))

(module+ main
  (display-to-file (unicode-source) output #:exists 'truncate/replace))
