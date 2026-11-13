# A table of names to addresses that every task and every importer shares: one table per run.
NAMES: ATS[String, Address[Int]] = ATS.new()

def register(name: String, address: Address[Int]) -> Void
  NAMES.put(name, address)
end

def tell(name: String, n: Int) -> Result[Void]
  address = try NAMES.get(name)
  address.send(n, 1000)
end
