import HTTP from "std/http"
def main() -> Void
  HTTP.close_client(Result.unwrap!(HTTP.client()))
end

