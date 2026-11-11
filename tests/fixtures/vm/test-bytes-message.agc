# Test.eq shows a Bytes as quoted text: printable ASCII as is, the rest escaped as in a String's form (\e, \xFF),
# the first 32 bytes, also inside another value. to_s and inspect keep the hex form.
def main() -> Void
  reply = Bytes.from_list([43, 79, 75, 13, 10, 0, 255, 27, 34, 92, 9]).unwrap!
  puts(Test.eq(reply, "+OK\r\n".bytes).message)
  puts(Test.eq([reply], []).message)
  long = "0123456789abcdefghijklmnopqrstuvwxyz".bytes
  puts(Test.eq(long, "".bytes).message)
  puts(reply.inspect)
end
