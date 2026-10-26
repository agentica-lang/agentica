import Facade from "facade"
import Lib from "lib"

def main() -> Void
  address: Lib.Address = Facade.parse("a")
  case Facade.Option.Some(1)
    Lib.Option.Some(n) -> puts(n)
    Facade.Option.None -> puts(address.host)
  end
end
