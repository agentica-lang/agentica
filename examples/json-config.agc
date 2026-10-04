struct Service
  name: String
  port: Int
  enabled: Bool
end

def read_service(text: String) -> Result[Service]
  root = try JSON.parse(text)
  service = try JSON.get(root, "service")
  name = try JSON.string(try JSON.get(service, "name"))
  port = try JSON.int(try JSON.get(service, "port"))
  enabled = try JSON.bool(try JSON.get(service, "enabled"))
  if name == "" or port < 1 or port > 65535
    return error("invalid config")
  end
  return ok(Service(name: name, port: port, enabled: enabled))
end

def main() -> Void
  config = read_service(IO.read())
  if Result.ok?(config)
    puts(JSON.encode(Result.unwrap!(config)))
  else
    puts(JSON.encode({"error": "invalid config"}))
  end
end
