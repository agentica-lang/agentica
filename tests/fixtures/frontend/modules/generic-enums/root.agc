import Domain from "option"
def main() -> Void
  value: Domain.Option[Int] = Domain.Option.Some(7)
  case value do
    Domain.Option.Some(item) ->
      puts(String.from_int(item))
    Domain.Option.None ->
      puts("empty")
  end
  empty: Domain.Option[String] = Domain.Option.None()
  case empty do
    Domain.Option.Some(item) ->
      puts(item)
    Domain.Option.None ->
      puts("none")
  end
end

