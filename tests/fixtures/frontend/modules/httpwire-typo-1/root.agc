import HTTP from "std/http"
def main() -> Void
  x = get_respons(1)
  puts(HTTP.proxy_from_env("x"))
end

