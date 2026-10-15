import Models from "models"
import Queue from "std/queue"

def main() -> Void
  user = Models.User(name: "ana", age: 3)
  older = user.with(age: 4)
  puts(Models.describe(older))
  puts(Models.names(["x", "y"]).size)
  q = Queue.new()
  puts(q)
  puts(Models.Status.Active)
end
