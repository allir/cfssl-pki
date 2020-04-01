# CFSSL PKI

Setting up your own PKI using [CFSSL](https://github.com/cloudflare/cfssl)

## Requirements

* cfssl

### Installing Requirements

#### macOS

`brew install cfssl`

## Using

### Setup CA

#### Generate the CA key and certificate

This will generate the new key and certificate based on the `ca.csr.json` template.

```bash
cfssl gencert -initca ca.csr.json | cfssljson -bare ca
```

#### Create CA config

Configure the CA to have a default profile and an authenticated profile. The default profile will issues certificates for 1 year while the authenticated one will issue certificates for 5 years. For the authentication we generate a new random `AUTH_KEY` for the `auth` profile and save it in the CA config `ca.service.json`.

```bash
hexdump -n 16 -e '4/4 "%08X" 1 "\n"' /dev/random > auth_key

AUTH_KEY=$(cat auth_key)
sed -i "s/REPLACE_AUTH_KEY_HERE/${AUTH_KEY}/" ca.config.json
```

### Requesting certificates locally

#### Request a certificate

Request new certificates using the certificate and key files for the CA. We'll use the same CSR but save two versions of it, one using the default signing profile and the other using the authenticated one.
We can then run `cfssl certinfo` to verify the difference, one being valid for one year while the other is valid for five.

```bash
cfssl gencert -config ca.config.json -ca ca.pem -ca-key ca-key.pem local.csr.json | cfssljson -bare local
cfssl gencert -config ca.config.json -profile auth -ca ca.pem -ca-key ca-key.pem local.csr.json | cfssljson -bare local-auth

# Should have "not_after" date in one year
cfssl certinfo -cert local.pem
# Should have "not_after" date in five years
cfssl certinfo -cert local-auth.pem
```

### Requesting certificates remotely

#### Run the CA as a service

This will run the CA service, listening on port 8888, using the configuration file.

```bash
cfssl serve -ca-key ca-key.pem -ca ca.pem -config ca.config.json
```

#### Request a certificate

Request new certificates as a "remote" client. We'll use the same CSR but save two versions of it, one using the default signing profile and the other using the authenticated one.
We can then run `cfssl certinfo` to verify the difference, one being valid for one year while the other is valid for five.

```bash
AUTH_KEY=$(cat auth_key)
sed -i "s/REPLACE_AUTH_KEY_HERE/${AUTH_KEY}/" client.config.json

cfssl gencert -config client.config.json remote.csr.json | cfssljson -bare remote
cfssl gencert -config client.config.json -profile auth remote.csr.json | cfssljson -bare remote-auth

# Should have "not_after" date in one year
cfssl certinfo -cert remote.pem
# Should have "not_after" date in five years
cfssl certinfo -cert remote-auth.pem
```
