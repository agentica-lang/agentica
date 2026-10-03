def main() -> Nil
  args = System.args()
  path: String = args[0]
  contents: Result[String] = File.read_text(path, 1000)
  if Result.ok?(contents)
    IO.inspect(String.length(Result.unwrap!(contents)))
  else
    IO.warn(Result.message(contents))
  end
end
