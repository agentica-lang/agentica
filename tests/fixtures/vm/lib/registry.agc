# A table of names to addresses that every task and every importer shares: one table per run.
export NAMES: ATS[String, Address[Int]] = ATS.new()

export def register(name: String, address: Address[Int]) -> Void
  NAMES.put(name, address)
end

export def tell(name: String, n: Int) -> Result[Void]
  address = try NAMES.get(name)
  address.send(n, 1000)
end
