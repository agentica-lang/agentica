# Local test certificates

`ca.pem` is a test-only CA. `server.pem` is signed by it and has the DNS SAN
`localhost`. `server-key.pem` is public test data, never a deployment key.
Certificates are valid for ten years from generation. The CA private key is
not retained. The fixtures test verified TLS in both directions, rejection
without explicit trust, and rejection of an incorrect hostname.

To replace the fixtures, generate a temporary RSA 2048-bit CA with OpenSSL
`req -x509`, `basicConstraints=critical,CA:TRUE` and a ten-year validity. Generate
a server CSR with `subjectAltName=DNS:localhost`, then sign it using `x509 -req`
with `-copy_extensions copy`. Replace all three PEM files together and delete
the temporary CA private key and CSR. OpenSSL is needed for regeneration only;
normal tests use the checked-in fixtures.
