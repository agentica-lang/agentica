import {NAMES} from "registry"

# Another module that reads the same table.
export def stop(name: String) -> Result[Void]
  address = try NAMES.get(name)
  address.send(0, 1000)
end
