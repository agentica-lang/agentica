#lang racket

(require rackunit
         "../src/diagnostic.rkt"
         "../src/source.rkt")

(define (problem text start-line start-column end-line end-column)
  (define input (source "t.agc" text))
  (diagnostic 'CHECK-TYPE-MISMATCH
              "expected Int, found String"
              (source-span input
                           (source-position 0 start-line start-column)
                           (source-position 0 end-line end-column))))

(module+ test
  (test-case "header, excerpt, and caret run"
    (check-equal? (format-diagnostic (problem "def main() -> Nil\n  age: Int = \"25\"\nend\n" 2 14 2 18))
                  (string-append "t.agc:2:14 error[CHECK-TYPE-MISMATCH]\n"
                                 "expected Int, found String\n\n"
                                 "2 |   age: Int = \"25\"\n"
                                 "  |              ^^^^")))

  (test-case "labels and help render under their lines"
    (define input (source "t.agc" "def f(a: Int, b: Float)\n  return a * b\nend\n"))
    (define (at line from to)
      (source-span input (source-position 0 line from) (source-position 0 line to)))
    (define problem
      (diagnostic 'CHECK-TYPE-MISMATCH "operator expects two values of the same type"
                  (at 2 12 13)
                  #:labels (list (cons (at 2 10 11) "this is Int") (cons (at 2 14 15) "this is Float"))
                  #:help "there is no Int to Float conversion"))
    (check-equal? (format-diagnostic problem)
                  (string-append "t.agc:2:12 error[CHECK-TYPE-MISMATCH]\n"
                                 "operator expects two values of the same type\n\n"
                                 "2 |   return a * b\n"
                                 "  |          - ^ -\n"
                                 "  |              this is Float\n"
                                 "  |          this is Int\n"
                                 "  = help: there is no Int to Float conversion")))

  (test-case "CRLF, multi-line, and end-of-line spans stay on the line"
    (check-equal? (format-diagnostic (problem "ab\r\ncd\r\n" 1 2 1 3))
                  "t.agc:1:2 error[CHECK-TYPE-MISMATCH]\nexpected Int, found String\n\n1 | ab\n  |  ^")
    (check-equal? (format-diagnostic (problem "abc\ndef\n" 1 2 2 2))
                  "t.agc:1:2 error[CHECK-TYPE-MISMATCH]\nexpected Int, found String\n\n1 | abc\n  |  ^^")
    (check-equal? (format-diagnostic (problem "abc" 2 1 2 1))
                  "t.agc:2:1 error[CHECK-TYPE-MISMATCH]\nexpected Int, found String\n\n2 | \n  | ^")))
