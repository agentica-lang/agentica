# Quit is the VM's force stop and Kill cannot be caught: subscribing to either stops the run at the list.
def main() -> Void
  _ = System.subscribe([System.Signal.Term, System.Signal.Quit])
  puts("not reached")
end
