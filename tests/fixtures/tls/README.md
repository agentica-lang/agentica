# Local test certificates

Test data only: every key here is public and never a deployment key.

`make-certs.sh` writes all of them at once, next to itself. It needs the
`openssl` command, 3.4 or newer for the expired certificate (`-not_before`
and `-not_after`). Last regenerated on 2026-10-12 with OpenSSL 3.5.7. Tests
use the checked-in files; nothing regenerates them during a test run.

- **File:** `ca.pem`
  - **What it is:** test CA (RSA 2048, CN "Agentica Test CA"); its private key
    is made in a temporary directory and not kept

- **File:** `server.pem`, `server-key.pem`
  - **What it is:** signed by the CA; SAN `DNS:localhost`, `IP:127.0.0.1`,
    `IP:::1`

- **File:** `wrong-host.pem`, `wrong-host-key.pem`
  - **What it is:** signed by the CA; SAN `DNS:wrong.example` (host name
    mismatch)

- **File:** `expired.pem`, `expired-key.pem`
  - **What it is:** signed by the CA for `localhost`, valid only on 2020-01-01

- **File:** `self-signed.pem`, `self-signed-key.pem`
  - **What it is:** self-signed for `localhost` (untrusted)

The other certificates are valid for 36,500 days, so they do not expire
during the project's life. They test verified TLS both ways, rejection
without explicit trust, a wrong host name, an expired and a self-signed
certificate, and the load errors of `TLS.listen`.
