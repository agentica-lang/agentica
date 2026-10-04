#lang racket

(require "../src/checker.rkt"
         "../src/diagnostic.rkt"
         "../src/evaluator.rkt"
         "../src/lexer.rkt"
         "../src/parser.rkt"
         "../src/source.rkt")

;; Run with: racket benchmarks/maps.rkt
;; End-to-end evaluation only: parsing/checking are outside the timed region.
;; Three samples per workload; no timing thresholds or extra dependencies.
(module+ main
  (displayln "entries workload median-ms")
  (for* ([count '(1000 10000 50000)] [reads? '(#f #t)])
    (define text
      (format (string-append
               "def main() -> Void\n"
               "  m: Map[Int, Int] = {}\n  i = 0\n"
               "  while i < ~a\n    m = Map.put(m, i, i)\n    i = i + 1\n  end\n"
               "~a"
               "end\n")
              count
              (if reads?
                  (format (string-append
                           "  total = 0\n  i = 0\n"
                           "  while i < ~a\n"
                           "    if Map.has_key?(m, i)\n      total = total + m[i]\n    end\n"
                           "    i = i + 1\n  end\n"
                           "  puts(String.from_int(total))\n") count)
                  "  puts(String.from_int(Map.size(m)))\n")))
    (define program
      (for/fold ([data (source "map-benchmark.agc" text)])
                ([stage (in-list (list lex parse check))])
        (define result (stage data))
        (when (diagnostic? result)
          (error 'map-benchmark "~a" (format-diagnostic result)))
        result))
    (define expected (format "~a\n" (if reads? (quotient (* count (sub1 count)) 2) count)))
    (define samples
      (for/list ([sample (in-range 3)])
        (collect-garbage)
        (define out (open-output-string))
        (define start (current-inexact-milliseconds))
        (define result (evaluate program #:out out))
        (define elapsed (- (current-inexact-milliseconds) start))
        (unless (and (eq? result 'nil) (equal? (get-output-string out) expected))
          (error 'map-benchmark "incorrect result: ~s, output: ~s" result (get-output-string out)))
        elapsed))
    (printf "~a ~a ~a\n" count (if reads? "build+read" "build")
            (real->decimal-string (cadr (sort samples <)) 2))))
