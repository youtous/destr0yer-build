#!/bin/bash

echo "Please enter your VAULT Password: "
read -sr VAULT_PASSWORD_INPUT
export VAULT_PASSWORD=$VAULT_PASSWORD_INPUT
