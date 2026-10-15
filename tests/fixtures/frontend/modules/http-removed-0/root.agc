import "std/http" as HTTP
def main() -> Void
  HTTP.respond(1, 200, [], "hi", 1000)
end

