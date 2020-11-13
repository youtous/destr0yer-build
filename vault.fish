#!/usr/bin/fish

echo "Please enter your VAULT Password: "
read -s VAULT_PASSWORD_INPUT
set -x VAULT_PASSWORD "$VAULT_PASSWORD_INPUT"
