import Models from "models"

def main() -> Void
  case Models.Shape.Boxed(Models.Option.Some(1))
    Models.Shape.Boxed(Models.Option.Some(n)) if n > 0 -> puts(n)
    Models.Shape.Boxed(_) -> puts(0)
  end
end
