# Phase 2 — Transport Security

## Filebeat to Logstash TLS

Application logs are transported from Filebeat to Logstash over TLS on
the Beats input port `5044`.

### Configuration

- Logstash enables TLS on its Beats input.
- Logstash presents `logstash.crt` and uses `logstash.key`.
- The server certificate includes the DNS subject alternative name
  `logstash`.
- Filebeat trusts the private CA through `ca.crt`.
- Filebeat uses `ssl.verification_mode: full`, validating both the
  certificate chain and the server hostname.
- Client certificate authentication is disabled
  (`ssl_client_authentication => "none"`). This is server-authenticated
  TLS, not mutual TLS.

### Certificate files

Certificates are stored under `security/certs/`.

| File | Purpose |
| --- | --- |
| `ca.crt` | CA certificate trusted by Filebeat |
| `ca.key` | Private CA signing key; host-only |
| `logstash.crt` | Logstash server certificate |
| `logstash.key` | Logstash server private key; mounted read-only |
| `logstash.csr` | Certificate signing request |
| `logstash.ext` | Certificate subject alternative name and usage extensions |

Private key files are excluded by the `security/certs/*.key` Git ignore
rule. The CA private key must never be mounted into application
containers or committed to the repository. Keep a secure, separate
backup of it if future certificate issuance is required.

The Logstash server certificate was issued with an 825-day validity
period. Track its expiry and renew it before expiration. The CA
certificate was issued with a 10-year validity period. After renewal,
update the certificate files and restart the affected services, then
repeat the verification below.

### Verification performed

1. Verified the Logstash certificate against the CA and checked the
   `logstash` hostname.
2. Ran `filebeat test output`; certificate-chain verification was
   enabled and the TLS handshake succeeded using TLS 1.3.
3. Confirmed the Beats protocol connection succeeded.
4. Created a unique JSON test event in the Filebeat input directory.
5. Found that exact event in Elasticsearch index `app-logs-000001`,
   matching its unique trace ID.

Test event:
- Service: `tls-verification`
- Trace ID: `tls-verification-20261119T081224Z`
- Message: `Filebeat to Logstash TLS verification`

This verifies the complete Filebeat → TLS → Logstash → Elasticsearch
path, rather than only a successful TLS handshake.

### Scope and limitations

- TLS protects the Filebeat-to-Logstash transport and authenticates
  the Logstash server to Filebeat.
- Mutual TLS client authentication is not enabled.
- Certificate renewal is a manual operational task.
- Private keys must remain protected and must not be added to Git.
