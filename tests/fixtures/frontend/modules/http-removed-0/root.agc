import HTTP from "std/http"
def main() -> Void
  HTTP.respond(1, 200, [], "hi", 1000)
end

