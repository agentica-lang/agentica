import {QueueState, new, push, pop as take} from "std/queue"

def main() -> Void
  q: QueueState = new()
  _ = take(push(q, "a"))
end
