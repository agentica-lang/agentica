#lang racket

(require rackunit json racket/runtime-path
         "../src/bdd.rkt" "../src/bdd-runner.rkt" "../src/diagnostic.rkt" "../src/source.rkt")

(define-runtime-path repository "..")
(define-runtime-path stream-spec "bdd/specs/json-lines.feature")

(define (docker . arguments)
  (define-values (process output input errors)
    (apply subprocess #f #f #f (find-executable-path "docker") arguments))
  (close-output-port input)
  (define text (port->string output))
  (define error-text (port->string errors))
  (subprocess-wait process)
  (close-input-port output)
  (close-input-port errors)
  (unless (zero? (subprocess-status process)) (error 'docker error-text))
  text)

(define (containers)
  (sort (string-split (docker "ps" "--all" "--filter" "name=agentica-bdd-" "--format" "{{.Names}}")) string<?))

(module+ test
  (when (equal? (getenv "AGENTICA_BDD_INTEGRATION") "1")
    (test-case "live JSON responses arrive before EOF and recover after errors"
      (define before (containers))
      (define report (run-bdd (list stream-spec) #:runtime (build-path repository "dist/runtime")))
      (check-true (hash-ref report 'ok) (format "~s" report))
      (check-equal? (hash-ref report 'passed) 2)
      (check-equal? (containers) before))

    (test-case "unflushed output times out, wrong output fails and later scenarios run"
      (define directory (make-temporary-file "agentica-bdd-integration~a" 'directory))
      (define before (containers))
      (dynamic-wind void
        (lambda ()
          (display-to-file "def main() -> Nil\n  line = IO.gets!()\n  puts(line)\n  line = IO.gets!()\nend\n" (build-path directory "buffered.agc"))
          (display-to-file "def main() -> Nil\n  puts(\"actual\")\n  IO.warn(\"warning\")\n  System.exit(3)\nend\n" (build-path directory "output.agc"))
          (display-to-file "def main() -> Nil\n  puts(String.join(List.repeat(\"x\", 1048576), \"\"))\nend\n" (build-path directory "oversized.agc"))
          (display-to-file
           (string-append
            "Feature: Lifecycle\nScenario: no flush\nGiven the Agentica program \"buffered.agc\"\n"
            "When I send the line \"hello\"\nThen I receive the line \"hello\" within 1000 milliseconds\n"
            "Scenario: wrong stdout\nGiven the Agentica program \"output.agc\"\n"
            "Then the program exits with code 3 within 5000 milliseconds\nAnd stdout is:\n  \"\"\"\n  incorrect\n  \"\"\"\n"
            "Scenario: wrong stderr\nGiven the Agentica program \"output.agc\"\n"
            "Then the program exits with code 3 within 5000 milliseconds\nAnd stderr is:\n  \"\"\"\n  incorrect\n  \"\"\"\n"
            "Scenario: wrong code\nGiven the Agentica program \"output.agc\"\nThen the program exits with code 0 within 5000 milliseconds\n"
            "Scenario: output limit\nGiven the Agentica program \"oversized.agc\"\nThen the program exits with code 0 within 5000 milliseconds\n"
            "Scenario: literal input and EOF\nGiven the Agentica program \"buffered.agc\"\nWhen I send input:\n  \"\"\"\n  hello\n  \"\"\"\nWhen I close stdin\nThen the program exits with code 1 within 5000 milliseconds\nAnd stdout is:\n  \"\"\"\n  hello\n\n  \"\"\"\n"
            "Scenario: later\nGiven the Agentica program \"output.agc\"\nThen the program exits with code 3 within 5000 milliseconds\n"
            "And stdout is:\n  \"\"\"\n  actual\n\n  \"\"\"\nAnd stderr is:\n  \"\"\"\n  warning\n\n  \"\"\"\n")
           (build-path directory "lifecycle.feature"))
          (define report (run-bdd (list directory) #:runtime (build-path repository "dist/runtime")))
          (check-equal? (hash-ref report 'passed) 2 (format "~s" report))
          (check-equal? (hash-ref report 'failed) 5)
          (define results (hash-ref (car (hash-ref report 'files)) 'scenarios))
          (check-equal? (hash-ref (hash-ref (car results) 'error) 'code) "RUNTIME-BDD-TIMEOUT")
          (for ([item (in-list (take (cdr results) 3))])
            (check-equal? (hash-ref (hash-ref item 'error) 'code) "RUNTIME-BDD-ASSERTION"))
          (check-equal? (hash-ref (hash-ref (list-ref results 4) 'error) 'code) "RUNTIME-BDD-OUTPUT-LIMIT"))
        (lambda () (delete-directory/files directory)))
      (check-equal? (containers) before))

    (test-case "candidate sees neither host specs nor provider environment and cannot write its source"
      (define directory (make-temporary-file "agentica-bdd-isolation~a" 'directory))
      (define context (make-bdd-context directory "agentica-eval:local" (build-path repository "dist/runtime")))
      (define span (source-span (source "isolation.feature" "") (source-position 0 1 1) (source-position 0 1 1)))
      (define before (containers))
      (dynamic-wind void
        (lambda ()
          (display-to-file "def main() -> Nil\n  line = IO.gets!()\nend\n" (build-path directory "blocked.agc"))
          (display-to-file "protected specification" (build-path directory "secret.feature"))
          (define environment (environment-variables-copy (current-environment-variables)))
          (environment-variables-set! environment #"AGENTICA_BDD_PROVIDER_SENTINEL" #"private-test-value")
          (parameterize ([current-environment-variables environment])
            (check-equal? (bdd-call context "BDD.given_program" '("blocked.agc") span) 'nil))
          (define created (filter (lambda (name) (not (member name before))) (containers)))
          (check-equal? (length created) 1)
          (define data
            (string->jsexpr
             (docker "exec" (car created) "node" "-e"
               (string-append
                "const fs=require('fs'),os=require('os');let writable=true;"
                "try{fs.writeFileSync('/workspace/target.agc','tampered')}catch(e){writable=false}"
                "process.stdout.write(JSON.stringify({uid:process.getuid(),writable,"
                "spec:fs.existsSync(process.argv[1]),provider:!!process.env.AGENTICA_BDD_PROVIDER_SENTINEL,"
                "network:Object.values(os.networkInterfaces()).flat().some(x=>!x.internal)}));")
               (path->string (build-path directory "secret.feature")))))
          (check-equal? data (hasheq 'uid 65534 'writable #f 'spec #f 'provider #f 'network #f)))
        (lambda () (bdd-cleanup! context) (delete-directory/files directory)))
      (check-equal? (containers) before))))
