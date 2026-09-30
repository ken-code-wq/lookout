#!/bin/zsh
# Creates "Lookout Local Signing", a self-signed code-signing certificate in the login keychain.
# It only needs to exist on this Mac: build-app.sh signs with it so macOS lists the desktop widgets
# (ad-hoc signed extensions are ignored) and keeps privacy permissions across rebuilds.
set -euo pipefail
if security find-identity -p codesigning | grep -q "Lookout Local Signing"; then
  echo "Lookout Local Signing already exists."; exit 0
fi
dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
cat > "$dir/cfg.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Lookout Local Signing
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$dir/key.pem" -out "$dir/cert.pem" -days 3650 -config "$dir/cfg.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$dir/key.pem" -in "$dir/cert.pem" -out "$dir/id.p12" -passout pass:lookout -name "Lookout Local Signing" 2>/dev/null
security import "$dir/id.p12" -k ~/Library/Keychains/login.keychain-db -P lookout -T /usr/bin/codesign
echo "Created Lookout Local Signing."
