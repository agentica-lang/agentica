import HTTP from "std/http"

def main() -> Void
  arguments = System.args()
  if List.size(arguments) != 1
    IO.warn("usage: http_get.agc URL")
    System.exit(2)
  end
  client = Result.unwrap!(HTTP.client(HTTP.client_options()))
  response = Result.unwrap!(HTTP.get(client, arguments[0]))
  puts(String.from_int(response.status))
  puts(response.body)
  HTTP.close_client(client)
end
