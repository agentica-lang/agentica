# Minimal MCP stdio server: initialize, ping, and an empty tools/list.
# Run: dist/agentica examples/mcp/stdio.agc
# One JSON-RPC message per line; stdout is reserved for protocol replies.

struct Envelope
  jsonrpc: String
  method: String
end

struct RpcResponse
  jsonrpc: String
  id: Json
  result: Json
end

struct RpcError
  code: Int
  message: String
end

struct EmptyObject
end

struct ServerInfo
  name: String
  version: String
end

struct Capabilities
  tools: EmptyObject
end

struct InitializeResult
  protocolVersion: String
  capabilities: Capabilities
  serverInfo: ServerInfo
end

struct ToolsResult
  tools: List[Json]
end

# Responses have different struct types; share only the text transport.
def send_message(text: String) -> Void
  puts(text)
  IO.flush()
end

def reply(id: Json, result: Json) -> Void
  response = RpcResponse(jsonrpc: "2.0", id: id, result: result)
  send_message(JSON.encode(response))
end

def reject(id: Json, code: Int, message: String) -> Void
  # `error` is a reserved field name, so only this envelope needs a map.
  problem = RpcError(code: code, message: message)
  response = {
    "jsonrpc": JSON.from("2.0"), "id": id, "error": JSON.from(problem)
  }
  send_message(JSON.encode(response))
end

def handle(text: String) -> Void
  parsed = JSON.parse(text)
  if not Result.ok?(parsed)
    reject(JSON.null(), -32700, "Parse error")
    return
  end
  request = Result.unwrap!(parsed)
  envelope = JSON.decode(text, Envelope)
  if not Result.ok?(envelope)
    reject(JSON.null(), -32600, "Invalid Request")
    return
  end
  fields = Result.unwrap!(envelope)
  if fields.jsonrpc != "2.0"
    reject(JSON.null(), -32600, "Invalid Request")
    return
  end

  request_id = JSON.get(request, "id")
  # Notifications, including notifications/initialized, have no response.
  if not Result.ok?(request_id)
    return
  end
  id = Result.unwrap!(request_id)
  if not (Result.ok?(JSON.string(id)) or Result.ok?(JSON.int(id)))
    reject(JSON.null(), -32600, "Invalid Request")
    return
  end

  if fields.method == "initialize"
    params = JSON.get(request, "params")
    if not Result.ok?(params)
      reject(id, -32602, "Invalid params")
      return
    end
    version = JSON.get(Result.unwrap!(params), "protocolVersion")
    if not Result.ok?(version)
      reject(id, -32602, "Invalid params")
      return
    end
    requested = JSON.string(Result.unwrap!(version))
    if not Result.ok?(requested)
      reject(id, -32602, "Invalid params")
      return
    end
    protocol = Result.unwrap!(requested)
    if protocol != "2024-11-05" and protocol != "2025-03-26" and protocol != "2025-06-18" and protocol != "2025-11-25"
      protocol = "2025-06-18"
    end
    result = InitializeResult(
      protocolVersion: protocol,
      capabilities: Capabilities(tools: EmptyObject()),
      serverInfo: ServerInfo(name: "agentica-ping", version: "0.1.0")
    )
    reply(id, JSON.from(result))
  elsif fields.method == "ping"
    reply(id, JSON.from(EmptyObject()))
  elsif fields.method == "tools/list"
    reply(id, JSON.from(ToolsResult(tools: [])))
  else
    reject(id, -32601, "Method not found")
  end
end

def main() -> Void
  while not IO.eof?()
    line = IO.gets()
    if not Result.ok?(line)
      return
    end
    handle(Result.unwrap!(line))
  end
end
