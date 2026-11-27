import HTTP from "std/http"

def main() -> Void
  arguments = System.args()
  if List.size(arguments) != 1
    IO.warn("usage: http_get.agc URL")
    System.exit(2)
  end
  response = Result.unwrap!(HTTP.get_response(arguments[0]))
  puts(response.status.to_s)
  puts(HTTP.text(response.body, response.headers).unwrap!)
end
