import {QueueState, new, push, pop as take} from "std/queue"

def main() -> Void
  q: QueueState = new()
  r = take(push(q, "a"))
end
