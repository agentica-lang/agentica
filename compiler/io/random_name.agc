## Random names for the files and folders the front end makes (the run folder of `agentica test`, the temporary files
## of the bytecode cache), and the hex form of bytes.

# The deadline of each system call, in milliseconds.
IO_TIMEOUT_MS = 10_000
DIGITS = "0123456789abcdef"

## A random name of 32 hex digits. Elsewhere it is 16 bytes of /dev/urandom, so it cannot be guessed (Random.int has a
## 31-bit seed when the program is run with --seed). Windows has no such file: the name is 8 bytes of Random.int, 4 of
## the clock and the process id, which is enough there because `Dir.mkdir_private` and the `create_private` mode fail
## on a name that is taken and make something that only its owner can use, so a guessed name costs a retry and gives
## no access.
export def hex() -> Result[String]
  if System.os() == "windows"
    return ok(hex_of(process_bytes()))
  end

  source = try File.open("/dev/urandom", "read", IO_TIMEOUT_MS)
  bytes: List[Int] = []
  while bytes.size < 16
    got = File.read_bytes(source, 16 - bytes.size, IO_TIMEOUT_MS)
    if !got.ok? or got.unwrap!.size == 0
      File.close(source, IO_TIMEOUT_MS)
      return error("cannot read /dev/urandom")
    end

    bytes = bytes.concat(got.unwrap!.to_a)
  end

  try File.close(source, IO_TIMEOUT_MS)
  return ok(hex_of(bytes))
end

## The bytes (each 0 to 255) as two lowercase hex digits each.
export def hex_of(bytes: List[Int]) -> String
  digits = bytes.map do |byte: Int| "#{DIGITS.slice(byte.shift_right(4), 1)}#{DIGITS.slice(byte.bit_and(15), 1)}" end

  return digits.join("")
end

# 8 bytes from Random.int, 4 from the clock and the process id as 4 bytes: 16 bytes like the name from /dev/urandom.
# The clock keeps the names from repeating when the user gives --seed, which makes Random.int deterministic.
def process_bytes() -> List[Int]
  pid = System.pid()
  now = Time.now_ms()
  bytes: List[Int] = []
  while bytes.size < 8
    bytes = bytes.push(Random.int(0, 255))
  end

  for shift in [24, 16, 8, 0]
    bytes = bytes.push(now.shift_right(shift).bit_and(255))
  end

  for shift in [24, 16, 8, 0]
    bytes = bytes.push(pid.shift_right(shift).bit_and(255))
  end

  return bytes
end
