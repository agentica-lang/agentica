#lang racket

(require rackunit "../src/gherkin.rkt" "../src/source.rkt" "../src/diagnostic.rkt")

(define (parse-text text) (parse-gherkin (source "sample.feature" text)))

(module+ test
  (test-case "outlines expand background, arguments, tags and source locations"
    (define parsed
      (parse-text
       (string-append
        "@stream\nFeature: streaming\n  Description\n\nBackground: setup\n  Given ready\n"
        "@case\nScenario Outline: value <n>\n  When input:\n    \"\"\"json\n    {\"n\":<n>}\n    \"\"\"\n"
        "  Then rows:\n    | key | value |\n    | a\\|b | <n> |\n    | pipe\\| | slash\\\\|\n  And finished\n"
        "  @examples\n  Examples:\n    | n |\n    | 1 |\n    | 2 |\n")))
    (check-true (feature? parsed))
    (define items (feature-scenarios parsed))
    (check-equal? (map scenario-name items) '("value 1" "value 2"))
    (check-equal? (scenario-tags (car items)) '("@stream" "@case" "@examples"))
    (define actions (scenario-steps (car items)))
    (check-equal? (map step-kind actions) '(Given When Then Then))
    (check-equal? (step-doc (cadr actions)) "{\"n\":1}")
    (check-equal? (step-table (caddr actions)) '(("key" "value") ("a|b" "1") ("pipe|" "slash\\")))
    (check-equal? (source-position-line (source-span-start (scenario-example-span (car items)))) 21)
    (check-equal? (source-position-line (source-span-start (step-span (cadr actions)))) 9))

  (test-case "invalid and unsupported syntax returns a located diagnostic"
    (for ([entry
           '(("" PARSE-GHERKIN-HEADER)
             ("Feature: empty\n" PARSE-GHERKIN-EMPTY)
             ("Feature: f\nScenario: empty\n" PARSE-GHERKIN-EMPTY)
             ("Feature: f\nScenario: s\nAnd missing\n" PARSE-GHERKIN-STEP)
             ("Feature: f\nRule: rule\n" PARSE-GHERKIN-UNSUPPORTED)
             ("# language: es\nFeature: f\n" PARSE-GHERKIN-UNSUPPORTED)
             ("Feature: f\nScenario: s\nThen: typo\n" PARSE-GHERKIN-UNSUPPORTED)
             ("Feature: f\nScenario: s\nThen rows:\n| a | b |\n| c |\n" PARSE-GHERKIN-TABLE)
             ("Feature: f\nScenario: s\nThen rows:\n| a | ignored\\|\n" PARSE-GHERKIN-TABLE)
             ("Feature: f\nScenario Outline: s\nThen fine\nExamples:\n| n |\n| 7 | ignored\\|\n" PARSE-GHERKIN-TABLE)
             ("Feature: f\nScenario: s\n|a|" PARSE-GHERKIN-ARGUMENT)
             ("Feature: f\nScenario: s\n\"\"\"\n\"\"\"" PARSE-GHERKIN-ARGUMENT)
             ("Feature: f\nScenario Outline: s\nThen fine\nExamples:\n|\n|\n" PARSE-GHERKIN-TABLE)
             ("Feature: f\nScenario Outline: <missing>\nThen fine\nExamples:\n| x |\n| 1 |\n" PARSE-GHERKIN-PARAMETER)
             ("Feature: f\nScenario Outline: s\nThen fine\n" PARSE-GHERKIN-EXAMPLES)
             ("Feature: f\nScenario: s\nWhen input:\n\"\"\"\nunfinished\n" PARSE-GHERKIN-ARGUMENT))])
      (define result (parse-text (car entry)))
      (check-true (diagnostic? result))
      (check-equal? (diagnostic-code result) (cadr entry))
      (check-equal? (source-name (source-span-source (diagnostic-span result))) "sample.feature"))))
