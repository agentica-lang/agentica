def main() -> Void
  arguments = System.args()
  if List.size(arguments) != 1
    IO.warn("usage: http_get.agc URL")
    System.exit(2)
  end
  client = Result.unwrap!(HTTP.client())
  response = Result.unwrap!(HTTP.get(client, arguments[0]))
  puts(String.from_int(response.status))
  puts(Result.unwrap!(HTTP.text(response.body, 30000)))
  HTTP.close_client(client)
end
