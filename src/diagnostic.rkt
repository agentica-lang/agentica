#lang racket

(require "source.rkt")

(provide (struct-out diagnostic)
         format-diagnostic)

(struct diagnostic (code message span) #:transparent)

(define (source-line text line)
  (define lines (string-split text "\n" #:trim? #f))
  (if (<= 1 line (length lines))
      (string-trim (list-ref lines (sub1 line)) "\r" #:left? #f)
      ""))

(define (format-diagnostic problem)
  (define span (diagnostic-span problem))
  (define start (source-span-start span))
  (define end (source-span-end span))
  (define line (source-position-line start))
  (define column (source-position-column start))
  (define text (source-line (source-text (source-span-source span)) line))
  (define room (max 1 (- (string-length text) (sub1 column))))
  (define wanted
    (if (= (source-position-line end) line)
        (- (source-position-column end) column)
        room))
  (define gutter (number->string line))
  (format "~a:~a:~a error[~a]\n~a\n\n~a | ~a\n~a | ~a~a"
          (source-name (source-span-source span))
          line
          column
          (diagnostic-code problem)
          (diagnostic-message problem)
          gutter
          text
          (make-string (string-length gutter) #\space)
          (make-string (sub1 column) #\space)
          (make-string (max 1 (min wanted room)) #\^)))
