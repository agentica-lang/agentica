import "std/http" as HTTP
def main() -> Void
  HTTP.close_client(Result.unwrap!(HTTP.client(HTTP.client_options())))
end

