import "modules/json-tools" as Tools

def main() -> Void
  args = Result.unwrap!(JSON.decode("{\"left\":20,\"right\":22}", Tools.AddArgs))
  result = Tools.add(args)
  reply = JSON.object({"result": JSON.from(result)})
  puts(JSON.encode(reply))
  IO.inspect(List.map([1, 2], &Tools.double))
  puts(JSON.encode(JSON.schema(Tools.AddArgs)))
end
