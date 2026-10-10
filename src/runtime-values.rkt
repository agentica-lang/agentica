#lang racket

(provide (struct-out instance) (struct-out mapping) (struct-out exit-code)
         (struct-out function-value) (struct-out closure-value) (struct-out result-ok) (struct-out result-error)
         (struct-out enum-value) mapping-put)

(struct instance (type-name fields) #:transparent)
(struct mapping (table reversed-keys) #:transparent)
(struct exit-code (code) #:transparent)
(struct function-value (name) #:transparent)
(struct closure-value (block captured))
(struct result-ok (value) #:transparent)
(struct result-error (message) #:transparent)
(struct enum-value (type-name variant-name payload) #:transparent)

(define (mapping-put target key value)
  (define table (mapping-table target))
  (mapping (hash-set table key value)
           (if (hash-has-key? table key)
               (mapping-reversed-keys target)
               (cons key (mapping-reversed-keys target)))))
