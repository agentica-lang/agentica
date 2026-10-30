# The kind of a FileInfo is Ruby's File::Stat#ftype name. FIFOs, sockets and links need a host peer to make them
# (tests/test_vm_os.py); the null device is on every system, as /dev/null or NUL.
def show(label: String, result: Result[FileInfo]) -> Void
  puts("#{label} #{Result.unwrap!(result).kind}")
end

def main() -> Void
  dir: String = System.args()[0]
  file = Result.unwrap!(Path.join([dir, "plain.txt"]))
  File.write_text(file, "data", 60000)
  device = {"windows": "NUL"}.get(System.os(), "/dev/null")
  show("dir", File.stat(dir, 60000))
  show("file", File.stat(file, 60000))
  show("device", File.stat(device, 60000))
  show("device lstat", File.lstat(device, 60000))
end
