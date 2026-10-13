struct Target
  scheme: String
  host: String
  port: Int
  target: String
end

struct Service
  server: HttpServer
  handler: Fn[HttpRequest, Result[HttpResponse]]
  options: HttpServerOptions
end

export def client_options() -> HttpClientOptions
  return HttpClientOptions(timeout_ms: 30000, idle_timeout_ms: 30000, max_connections: 4, max_body_bytes: 1048576, ca_file: "")
end

export def client(options: HttpClientOptions) -> Result[HttpClient]
  try check_options(options.timeout_ms, options.idle_timeout_ms, options.max_connections, options.max_body_bytes)
  return HttpWire.client(options.timeout_ms, options.idle_timeout_ms, options.max_connections, options.max_body_bytes, options.ca_file)
end

def check_options(timeout_ms: Int, idle_timeout_ms: Int, max_connections: Int, max_body_bytes: Int) -> Result[Void]
  if timeout_ms <= 0 or idle_timeout_ms <= 0 or max_connections <= 0 or max_body_bytes <= 0
    return error("http: every option must be positive")
  end
  if max_connections > 65536
    return error("http: max_connections must be at most 65536")
  end
  if max_body_bytes > 67108864
    return error("http: max_body_bytes must be at most 67108864")
  end
  return ok()
end

export def close_client(pool: HttpClient) -> Void
  HttpWire.close_client(pool)
end

export def get(pool: HttpClient, url: String) -> Result[HttpResponse]
  return request(pool, "GET", url, [], "")
end

export def post(pool: HttpClient, url: String, headers: List[Header], body: String) -> Result[HttpResponse]
  return request(pool, "POST", url, headers, body)
end

export def request(pool: HttpClient, method: String, url: String, headers: List[Header], body: String) -> Result[HttpResponse]
  where = try parse_url(url)
  return HttpWire.exchange(pool, where.scheme, where.host, where.port, method, where.target, headers, body)
end

export def header_values(headers: List[Header], name: String) -> List[String]
  wanted = String.downcase(name)
  found: List[String] = []
  for header in headers
    if String.downcase(header.name) == wanted
      found = List.append(found, header.value)
    end
  end
  return found
end

def first_of(text: String, part: String) -> Int
  return Result.unwrap_or(String.index_of(text, part), String.length(text))
end

def rest_of(text: String, start: Int) -> String
  return String.slice(text, start, String.length(text) - start)
end

def plain?(text: String, digits_only: Bool) -> Bool
  for c in String.split(text, "")
    code = String.code(c)
    if code < 33 or code > 126 or (digits_only and (code < 48 or code > 57))
      return false
    end
  end
  return true
end

def ipv6?(text: String) -> Bool
  if not String.contains?(text, ":")
    return false
  end
  for c in String.split(text, "")
    code = String.code(c)
    if not ((code >= 48 and code <= 58) or (code >= 65 and code <= 70) or (code >= 97 and code <= 102) or code == 46)
      return false
    end
  end
  return true
end

def bad_url() -> Result[Target]
  return error("http: the URL must be http:// or https:// with a host, and without user info")
end

def parse_url(url: String) -> Result[Target]
  split = first_of(url, "://")
  scheme = String.downcase(String.slice(url, 0, split))
  if split == String.length(url) or (scheme != "http" and scheme != "https")
    return bad_url()
  end
  rest = rest_of(url, split + 3)
  rest = String.slice(rest, 0, first_of(rest, "#"))
  stop = first_of(rest, "/")
  query = first_of(rest, "?")
  if query < stop
    stop = query
  end
  authority = String.slice(rest, 0, stop)
  target = rest_of(rest, stop)
  if not String.starts_with?(target, "/")
    target = "/" + target
  end
  host = authority
  port_text = ""
  if String.starts_with?(authority, "[")
    close = first_of(authority, "]")
    if close == String.length(authority)
      return bad_url()
    end
    host = String.slice(authority, 1, close - 1)
    if not ipv6?(host)
      return bad_url()
    end
    after = rest_of(authority, close + 1)
    if after != ""
      if after == ":" or not String.starts_with?(after, ":")
        return bad_url()
      end
      port_text = rest_of(after, 1)
    end
  elsif String.contains?(authority, ":")
    colon = first_of(authority, ":")
    host = String.slice(authority, 0, colon)
    port_text = rest_of(authority, colon + 1)
    if port_text == ""
      return bad_url()
    end
  end
  if host == "" or String.contains?(authority, "@") or not plain?(host, false) or not plain?(port_text, true)
    return bad_url()
  end
  port = 80
  if scheme == "https"
    port = 443
  end
  if String.length(port_text) > 5
    return error("http: the port must be 1..65535")
  end
  if port_text != ""
    port = String.to_int!(port_text)
  end
  if port < 1 or port > 65535
    return error("http: the port must be 1..65535")
  end
  return ok(Target(scheme: scheme, host: String.downcase(host), port: port, target: target))
end

export def server_options() -> HttpServerOptions
  return HttpServerOptions(request_timeout_ms: 30000, idle_timeout_ms: 30000, max_connections: 128, max_body_bytes: 1048576)
end

export def listen(host: String, port: Int, handler: Fn[HttpRequest, Result[HttpResponse]], options: HttpServerOptions) -> Result[HttpServer]
  try check_options(options.request_timeout_ms, options.idle_timeout_ms, options.max_connections, options.max_body_bytes)
  listener = try TCP.listen(host, port)
  return ok(start(listener, handler, options))
end

export def listen_tls(host: String, port: Int, cert_file: String, key_file: String, handler: Fn[HttpRequest, Result[HttpResponse]], options: HttpServerOptions) -> Result[HttpServer]
  try check_options(options.request_timeout_ms, options.idle_timeout_ms, options.max_connections, options.max_body_bytes)
  listener = try TLS.listen(host, port, cert_file, key_file)
  return ok(start(listener, handler, options))
end

export def local_port(server: HttpServer) -> Int
  return HttpWire.local_port(server)
end

export def wait(server: HttpServer) -> Result[Void]
  return HttpWire.wait(server)
end

export def close_server(server: HttpServer) -> Void
  HttpWire.close_server(server)
end

def start(listener: Listener, handler: Fn[HttpRequest, Result[HttpResponse]], options: HttpServerOptions) -> HttpServer
  return HttpWire.server(listener, options.max_connections) do |server|
    accept_all(Service(server: server, handler: handler, options: options))
  end
end

def accept_all(service: Service) -> Void
  while true
    case HttpWire.accept(service.server)
      ok(socket) -> HttpWire.spawn(service.server, socket) do |s| serve(s, service) end
      error(_) -> return
    end
  end
end

def serve(socket: Socket, service: Service) -> Void
  options = service.options
  wait_ms = options.request_timeout_ms
  while true
    case HttpWire.read_request(socket, wait_ms, options.request_timeout_ms, options.max_body_bytes)
      ok(request) ->
        if not answer(socket, request, service)
          return
        end
      error(_) -> return
    end
    wait_ms = options.idle_timeout_ms
  end
end

def answer(socket: Socket, request: HttpRequest, service: Service) -> Bool
  timeout = service.options.request_timeout_ms
  case service.handler.call(request)
    ok(response) ->
      case HttpWire.write_response(socket, request, response, timeout)
        ok(keep) -> return keep
        error(message) ->
          if String.starts_with?(message, "http: invalid response: ")
            IO.warn(message)
            failed(socket, request, timeout)
          end
      end
    error(message) ->
      IO.warn("http: handler error: #{message}")
      failed(socket, request, timeout)
  end
  return false
end

def failed(socket: Socket, request: HttpRequest, timeout: Int) -> Void
  HttpWire.write_response(socket, request, HttpResponse(status: 500, headers: [Header(name: "Connection", value: "close")], body: ""), timeout)
end
