def main() -> Void
  dir: String = System.args()[0]
  secret = Result.unwrap!(Path.join([dir, "private"]))
  Dir.mkdir_private(secret, 60000)
  info = Result.unwrap!(File.lstat(secret, 60000))
  puts("dir #{info.kind} #{info.mode}")
  file = Result.unwrap!(Path.join([secret, "secret.bin"]))
  handle = Result.unwrap!(File.open(file, "create_private", 60000))
  File.write(handle, "top secret", 60000)
  File.close(handle, 60000)
  info = Result.unwrap!(File.lstat(file, 60000))
  puts("file #{info.kind} #{info.size_bytes} #{info.mode}")
  followed = Result.unwrap!(File.stat(file, 60000))
  puts("followed #{followed.kind} #{followed.mode}")
  Path.remove(secret, 60000)
end
