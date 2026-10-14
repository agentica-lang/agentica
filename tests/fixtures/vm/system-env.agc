def show(name: String) -> Void
  IO.inspect(System.env(name))
end

def main() -> Void
  show("AGC_ENV_SET")
  show("AGC_ENV_EMPTY")
  show("AGC_ENV_EQUALS")
  show("AGC_ENV_UNICODE")
  show("AGC_ENV_UNSET")
  show("agc_env_set")
  show("AGC_ENV")
  show("AGC_ENV_SET_")
  show("")
  show("=")
  show("AGC_ENV_SET=value")
  show("AGC_ENV_SET" + String.from_code(0))
  IO.inspect(System.env("AGC_ENV_EMPTY").ok?)
  IO.inspect(System.env("AGC_ENV_UNSET").ok?)
  IO.inspect(System.env("AGC_ENV_EMPTY").unwrap_or("fallback"))
  IO.inspect(System.env("AGC_ENV_UNSET").unwrap_or("fallback"))
  IO.inspect(System.env("AGC_ENV_SET").unwrap_or("fallback") + "!")
end
