# CFSSL PKI

Setting up your own PKI using [CFSSL](https://github.com/cloudflare/cfssl) with OCSP and CRL.

## Requirements

* openssl
* cfssl
* sqlite
* jq (for magic)

### Installing Requirements

#### macOS

`brew install openssl cfssl sqlite jq`

## Using

### Setup CA & Intermediate

#### Generate the CA key, certificate and configuration

This will generate the new key and certificate based on the `ca.csr.json` template.

```bash
cfssl gencert -initca ca.csr.json | cfssljson -bare ca
```

Generate an `AUTH_KEY` that we'll use for authenticated requests.

```bash
hexdump -n 16 -e '4/4 "%08X" 1 "\n"' /dev/random > auth_key
```

Configure the CA to have a default profile and an authenticated profile. The default profile will issues certificates for 1 year while the authenticated one will issue certificates for 5 years. For the authentication we generate a new random `AUTH_KEY` for the `auth` profile and save it in the CA config `ca.config.json`.

```bash
AUTH_KEY=$(cat auth_key)
sed -i "s/REPLACE_AUTH_KEY_HERE/${AUTH_KEY}/" ca.config.json
```

#### Generate Intermediate key, certificate and configuration.

We'll generate a new intermediate CA and sign it using the Root CA.

```bash
cfssl gencert -initca intermediate.csr.json | cfssljson -bare intermediate
cfssl sign -ca ca.pem -ca-key ca-key.pem -config ca.config.json -profile intermediate intermediate.csr | cfssljson -bare intermediate
```

### Setting up OCSP and CRL

OCSP and CRL require a certificate database. We'll use `sqlite` for this here. But ofcourse you could use another database. For more information check out [CFSSL on Github](https://github.com/cloudflare/cfssl/tree/master/certdb). We use `db.config.json` to point to the database when we'll start up our cfssl server later.


```bash
cat scripts/create-certificate-db-sqlite.sql | sqlite3 cert.db
```

We also set up a certificate for the OCSP responder, using `ocsp.csr.json`. It should be issued by the "serving CA", in this case the Intermediate CA since that's what we'll be using to issue the server and client certificates.

```bash
cfssl gencert -config ca.config.json -profile ocsp -ca intermediate.pem -ca-key intermediate-key.pem ocsp.csr.json | cfssljson -bare ocsp
```

### Requesting Certificates

#### Request a certificate locally

Request new certificates using the certificate and key files for the Intermediate CA. We'll use the same CRL but use different profiles and filenames for the issued certificates.
We can then use `openssl` to verify the difference, one is a Server certificate while the other is a Client certificate.
*Note you can inspect the certificates using `cfssl certinfo -cert <certificate>` to inspect certificates too, but it won't show usages.*

```bash
cfssl gencert -config ca.config.json -profile server -ca intermediate.pem -ca-key intermediate-key.pem local.csr.json | cfssljson -bare local-server
cfssl gencert -config ca.config.json -profile client -ca intermediate.pem -ca-key intermediate-key.pem local.csr.json | cfssljson -bare local-client

# Should have extended key usage for Server Auth
openssl x509 -text -noout -in local-server.pem
# Should have extended key usage for Client Auth
openssl x509 -text -noout -in local-client.pem

# Verify the certificates
cat ca.pem intermediate.pem > ca_bundle.pem
openssl verify -CAfile ca_bundle.pem local-server.pem
openssl verify -CAfile ca_bundle.pem local-client.pem
```

#### Requesting certificates remotely

First we need to run the Intermediate CA as a service, listening on port 8888, using the configuration file.

```bash
cfssl serve -ca intermediate.pem -ca-key intermediate-key.pem -config ca.config.json -db-config db.config.json -responder ocsp.pem -responder-key ocsp-key.pem
```

Then we request new certificates as a "remote" client using `client.config.json`. We'll use the same CSR but save two versions of it, a Server and Client certificate.
We can then run `openssl` to verify the difference.
*Note you can inspect the certificates using `cfssl certinfo -cert <certificate>` to inspect certificates too, but it won't show usages.*

```bash
AUTH_KEY=$(cat auth_key)
sed -i "s/REPLACE_AUTH_KEY_HERE/${AUTH_KEY}/" client.config.json

cfssl gencert -config client.config.json -profile server remote.csr.json | cfssljson -bare remote-server
cfssl gencert -config client.config.json -profile client remote.csr.json | cfssljson -bare remote-client

# Should have extended key usage for Server Auth
openssl x509 -text -noout -in remote-server.pem
# Should have extended key usage for Client Auth
openssl x509 -text -noout -in remote-client.pem

# Verify the certificates
cat ca.pem intermediate.pem > ca_bundle.pem
openssl verify -CAfile ca_bundle.pem remote-server.pem
openssl verify -CAfile ca_bundle.pem remote-client.pem
```

### Revoking Certificates and OCSP responder

Let's revoke one of the certificates we issued above (remote-server). The revokation endpoint expects the serial number and authority key id as parameters so let's get those first. It's nice to use `jq` here for some parsing.
*Also, the authority key id needs to be all lowercase and without semicolons so we use `tr` to manupulate the string from the output.*

```bash
SERIAL=$(cfssl certinfo -cert remote-server.pem | jq -r '.serial_number')
AUTH_KEY_ID=$(cfssl certinfo -cert remote-server.pem | jq '.authority_key_id' | tr -dc '[:alnum:]' | tr '[:upper:]' '[:lower:]')

curl localhost:8888/api/v1/cfssl/revoke --data @<(cat <<EOF
{
    "serial": "${SERIAL}",
    "authority_key_id": "${AUTH_KEY_ID}"
}
EOF
)
```

This should return `{"success":true,"result":{},"errors":[],"messages":[]}` which means the revocation succeeded. **BTW, I have no idea why this endpoint works without using the API KEY?** ¯\\_(ツ)_/¯

Before we start up the OCSP responder and verify, there are some caveats with the CFSSL OCSP responder… It’s doesn’t update the OCSP table on the fly, and the responder also isn’t updated on the fly. So, when you issue or revoke certificate, you need to update OCSP table and dump it’s data to file, and restart OCSP responder.

First we update the table and dump the information to a file that can be served with `cfssl ocspserve`.

```bash
cfssl ocsprefresh -db-config db.config.json -responder ocsp.pem -responder-key ocsp-key.pem -ca intermediate.pem
cfssl ocspdump -db-config db.config.json > ocsp_data.txt
```

Then start up the service. It needs to be on a different port than the CFSSL serve from above as we want to run both.

```bash
cfssl ocspserve -port 8889 -responses ocsp_data.txt
```

And finally we verify the revocation using `openssl`, which will tell you that the certificate is indeed revoked.

```bash
cat ca.pem intermediate.pem > ca_bundle.pem
openssl ocsp -issuer intermediate.pem -no_nonce -cert remote-server.pem -CAfile ca_bundle.pem -url http://localhost:8889
```

### Cleanup

Clean up all the stuff to reset the repo.

```bash
git clean -xf
git restore .
```

## Resources

Some links for further reading. Shoutout to the guide over at propellered.com which this is very much based on.

* https://github.com/cloudflare/cfssl
* https://propellered.com/posts/cfssl_setting_up
