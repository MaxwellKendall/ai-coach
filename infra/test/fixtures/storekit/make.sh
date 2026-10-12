#!/bin/sh
# FIT-123: a test chain shaped like Apple's App Store signing chain (root, intermediate with Apple's WWDR OID, leaf
# with the App Store receipt-signing OID), so the proxy's JWS check can be tested. Test-only keys; never trusted in AWS.
set -e
cd "$(dirname "$0")"
ext() { printf "basicConstraints=critical,%s\nkeyUsage=critical,%s\n%s\n" "$1" "$2" "$3"; }
openssl ecparam -name prime256v1 -genkey -noout -out root.key
openssl req -x509 -new -key root.key -subj "/CN=Test Root" -days 7300 -out root.pem
openssl ecparam -name prime256v1 -genkey -noout -out intermediate.key
openssl req -new -key intermediate.key -subj "/CN=Test Intermediate" -out intermediate.csr
ext "CA:true" "keyCertSign" "1.2.840.113635.100.6.2.1=ASN1:NULL" > intermediate.ext
openssl x509 -req -in intermediate.csr -CA root.pem -CAkey root.key -CAcreateserial -days 7300 -extfile intermediate.ext -out intermediate.pem
openssl ecparam -name prime256v1 -genkey -noout -out leaf.key
openssl pkcs8 -topk8 -nocrypt -in leaf.key -out leaf.pkcs8.key
openssl req -new -key leaf.key -subj "/CN=Test Leaf" -out leaf.csr
ext "CA:false" "digitalSignature" "1.2.840.113635.100.6.11.1=ASN1:NULL" > leaf.ext
openssl x509 -req -in leaf.csr -CA intermediate.pem -CAkey intermediate.key -CAcreateserial -days 7300 -extfile leaf.ext -out leaf.pem
rm -f *.csr *.ext *.srl root.key intermediate.key leaf.key
