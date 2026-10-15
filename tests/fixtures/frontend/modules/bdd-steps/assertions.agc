import "std/bdd" as Spec
import "std/queue" as Queue

export def verify(ctx: Spec.Context, args: List[String]) -> Spec.Context
  q = Queue.push(Queue.new(), "imported handler")
  return Spec.assert(ctx, Result.unwrap!(Queue.peek(q)) == "imported handler", "imported handler")
end

