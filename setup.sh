#!/usr/bin/env bash
set -euxo pipefail

hexdump -n 16 -e '4/4 "%08X" 1 "\n"' /dev/random > auth_key
AUTH_KEY=$(cat auth_key)
sed -i "s/REPLACE_AUTH_KEY_HERE/${AUTH_KEY}/" ca.config.json
sed -i "s/REPLACE_AUTH_KEY_HERE/${AUTH_KEY}/" client.config.json

sqlite3 cert.db < scripts/create-certificate-db-sqlite.sql

cfssl gencert -initca ca.csr.json | cfssljson -bare ca

cfssl gencert -initca intermediate.csr.json | cfssljson -bare intermediate
cfssl sign -ca ca.pem -ca-key ca-key.pem -config ca.config.json -profile intermediate intermediate.csr | cfssljson -bare intermediate

cfssl gencert -config ca.config.json -profile ocsp -ca intermediate.pem -ca-key intermediate-key.pem ocsp.csr.json | cfssljson -bare ocsp
