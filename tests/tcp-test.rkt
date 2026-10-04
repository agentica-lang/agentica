#lang racket

(require rackunit "network-support.rkt")

(define (client-program host port secure?)
  (format
   #<<AGC
def main() -> Void
  socket = Result.unwrap!(~a)
  Result.unwrap!(TCP.send_bytes(socket, [195], 1000))
  Result.unwrap!(TCP.send_bytes(socket, [177, 240, 159, 152, 128, 10], 1000))
  puts(Result.unwrap!(TCP.read_line(socket, 1000)))
  Result.unwrap!(TCP.send(socket, "abc", 1000))
  data: List[Int] = []
  while List.size(data) < 3
    part = Result.unwrap!(TCP.recv_bytes(socket, 3, 1000))
    for byte in part
      data = List.append(data, byte)
    end
  end
  IO.inspect(data)
  IO.inspect(Result.ok?(TCP.recv_bytes(socket, 1, 20)))
  TCP.close(socket)
  TCP.close(socket)
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  IO.inspect(Result.ok?(TCP.accept(listener, 20)))
  TCP.close_listener(listener)
end
AGC
   (if secure?
       (format "TLS.connect(~s, ~a, ~s, 2000)" host port (path->string ca-path))
       (format "TCP.connect(~s, ~a, 2000)" host port))))

(define (server-program secure?)
  (format
   #<<AGC
def echo(listener: Listener) -> Void
  socket = Result.unwrap!(TCP.accept(listener, 3000))
  line = Result.unwrap!(TCP.read_line(socket, 3000))
  Result.unwrap!(TCP.send(socket, line + "\n", 1000))
  TCP.close(socket)
end
def main() -> Void
  listener = Result.unwrap!(~a)
  puts(String.from_int(TCP.local_port(listener)))
  IO.flush()
  worker = Task.spawn(&echo, listener)
  Task.await(worker)
  IO.gets()
  TCP.close_listener(listener)
  TCP.close_listener(listener)
end
AGC
   (if secure?
       (format "TLS.listen(\"127.0.0.1\", 0, ~s, ~s)" (path->string cert-path) (path->string key-path))
       "TCP.listen(\"127.0.0.1\", 0)")))

(module+ test
  (when (node-available?)
    (test-case "TCP and verified TLS interoperate with Node bytes and fragmented UTF-8"
      (with-peers
       (lambda (ports)
         (check-equal? (run-program (client-program "127.0.0.1" (hash-ref ports 'tcp) #f)) "ñ😀\n[97, 98, 99]\nfalse\nfalse\n")
         (check-equal? (run-program (client-program "localhost" (hash-ref ports 'tls) #t)) "ñ😀\n[97, 98, 99]\nfalse\nfalse\n")
         (check-equal?
          (run-program
           (format "def main() -> Void\n  IO.inspect(Result.ok?(TLS.connect(\"127.0.0.1\", ~a, ~s, 1000)))\nend\n"
                   (hash-ref ports 'tls) (path->string ca-path))) "false\n"))))
    (test-case "Node clients verify Agentica TCP and TLS listeners through the real CLI"
      (for ([secure? '(#f #t)])
        (with-program-server (server-program secure?)
          (lambda (port) (check-equal? (node-client "tcp-client" port secure?) "tcp client ok\n")))))))
