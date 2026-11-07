# RSA.public_encrypt_oaep with the 2048-bit fixture key of tests/fixtures/rsa/
# in both public PEM forms: the ciphertext has the key's 256 bytes and differs
# on every call, and the data takes 0 to 214 bytes (256 - 42). Then the error
# Results: no PEM, a key that is not RSA, a private key, data too long, a text
# over 64 KiB, and RSA keys that OpenSSL refuses, made from DER here: a 256-bit
# modulus (too small for the padding), an exponent above the modulus and a
# modulus of 16400 bits (above OpenSSL's 16384). tests/test_vm_crypto.py has a
# Node peer decrypt the ciphertexts.
SPKI = (
  "-----BEGIN PUBLIC KEY-----\n" +
  "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAs1ZCN9Wxre/bu7dwEeju\n" +
  "bBLygVJkUck+jMQuh8glJPrdzdDsmANl87e/f2/AC2+hmGVaXDCQhORyMBqRT0NW\n" +
  "NhdqwGviyW+lp3h6494ioX3HPTXyoauDWT4Ur2CKaetLO0iH/54vGQGyKGsKxCdD\n" +
  "kGV6hiftn3LKzq3rQ2k4lPEbam2V4SppaSG/d7iR/l4qVzKbPbIa3QqK75JI+PbI\n" +
  "rj5O9zKgeWS1VCVLMjp5GmUH3blNqbMo4bqm8uEBwD0R4/XgksAyV/xwDn/YUGm5\n" +
  "Ge3bi1fuS5ec3N0d6Nym9ueD1PV/s8luy+YYpBxw6d1o5fN/rA+crcKQf4xyquRS\n" +
  "kQIDAQAB\n" +
  "-----END PUBLIC KEY-----\n"
)
PKCS1 = (
  "-----BEGIN RSA PUBLIC KEY-----\n" +
  "MIIBCgKCAQEAs1ZCN9Wxre/bu7dwEejubBLygVJkUck+jMQuh8glJPrdzdDsmANl\n" +
  "87e/f2/AC2+hmGVaXDCQhORyMBqRT0NWNhdqwGviyW+lp3h6494ioX3HPTXyoauD\n" +
  "WT4Ur2CKaetLO0iH/54vGQGyKGsKxCdDkGV6hiftn3LKzq3rQ2k4lPEbam2V4Spp\n" +
  "aSG/d7iR/l4qVzKbPbIa3QqK75JI+PbIrj5O9zKgeWS1VCVLMjp5GmUH3blNqbMo\n" +
  "4bqm8uEBwD0R4/XgksAyV/xwDn/YUGm5Ge3bi1fuS5ec3N0d6Nym9ueD1PV/s8lu\n" +
  "y+YYpBxw6d1o5fN/rA+crcKQf4xyquRSkQIDAQAB\n" +
  "-----END RSA PUBLIC KEY-----\n"
)
EC_PUBLIC = (
  "-----BEGIN PUBLIC KEY-----\n" +
  "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE8jYY7B3cBYRjm9JF+IwdZzSlAkB2\n" +
  "n+Wp2aTddxxDUnM7mgQ6btekhuBpxfVQ+5IW/C6Kf7Jx95klnHC4+kGPIg==\n" +
  "-----END PUBLIC KEY-----\n"
)
EC_PRIVATE = (
  "-----BEGIN PRIVATE KEY-----\n" +
  "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg87Ngr4zVVZKIIi1z\n" +
  "qEFFjiyoPZ+IZao3MjyGjf50f1mhRANCAATyNhjsHdwFhGOb0kX4jB1nNKUCQHaf\n" +
  "5anZpN13HENSczuaBDpu16SG4GnF9VD7khb8Lop/snH3mSWccLj6QY8i\n" +
  "-----END PRIVATE KEY-----\n"
)

def hex(text: String) -> Bytes
  return Digest.hexdecode(text).unwrap!
end

def zeros(n: Int) -> Bytes
  return Bytes.from_list(List.repeat(0, n)).unwrap!
end

# The PKCS#1 PEM of an RSAPublicKey in DER.
def pkcs1_pem(der: Bytes) -> String
  return "-----BEGIN RSA PUBLIC KEY-----\n" + Base64.encode64(der) + "-----END RSA PUBLIC KEY-----\n"
end

def shape(label: String, r: Result[Bytes]) -> Void
  if r.ok?
    puts("#{label} ok size=#{r.unwrap!.size}")
  else
    puts("#{label} error")
  end
end

def main() -> Void
  data = "scrambled password".bytes
  shape("spki", RSA.public_encrypt_oaep(SPKI, data))
  shape("pkcs1", RSA.public_encrypt_oaep(PKCS1, data))
  shape("empty data", RSA.public_encrypt_oaep(SPKI, "".bytes))
  shape("214 bytes", RSA.public_encrypt_oaep(SPKI, zeros(214)))
  shape("215 bytes", RSA.public_encrypt_oaep(SPKI, zeros(215)))
  first = RSA.public_encrypt_oaep(SPKI, data).unwrap!
  puts("fresh seed #{first != RSA.public_encrypt_oaep(SPKI, data).unwrap!}")
  shape("no text", RSA.public_encrypt_oaep("", data))
  shape("no pem", RSA.public_encrypt_oaep("MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAs1ZCN9Wxre", data))
  shape("cut pem", RSA.public_encrypt_oaep(SPKI.slice(0, 200), data))
  shape("ec key", RSA.public_encrypt_oaep(EC_PUBLIC, data))
  shape("private key", RSA.public_encrypt_oaep(EC_PRIVATE, data))
  shape("64 KiB text", RSA.public_encrypt_oaep(List.repeat(" ", 65537).join("") + SPKI, data))
  # n = 2^255 + 1 and e = 65537: 32 bytes, too few for the 42 of the padding.
  small = hex("302802210080") + zeros(30) + hex("01") + hex("0203010001")
  shape("256-bit key", RSA.public_encrypt_oaep(pkcs1_pem(small), "".bytes))
  # n = 2^1023 + 1 and e = n + 2.
  n = hex("0281810080") + zeros(126)
  above = hex("30820108") + n + hex("01") + n + hex("03")
  shape("exponent above modulus", RSA.public_encrypt_oaep(pkcs1_pem(above), data))
  # n = 2^16399 + 1 and e = 65537.
  big = hex("3082080c028208030080") + zeros(2048) + hex("01") + hex("0203010001")
  shape("16400-bit key", RSA.public_encrypt_oaep(pkcs1_pem(big), data))
end
