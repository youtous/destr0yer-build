#!/bin/sh
# Generate bcrypt password hashes using htpasswd.
# Usage: ./scripts/bcrypt-password.sh username
# From https://unix.stackexchange.com/questions/307994/compute-bcrypt-hash-from-command-line

CMD=$(which htpasswd 2>/dev/null)
OPTS="-nBC 15"
USERNAME=$1

usage() {
    local script=$(basename "$0")
    cat <<EOF
$script: Generate Bcrypt Hashed Passwords using htpasswd

Usage: $script username

Requires: apache2-utils (apt install apache2-utils)

Copy the hash (after the username: prefix) into
podman_mailserver_domains[].accounts[].bcrypt_password
EOF
    exit 1
}

check_config() {
    if [ -z "$CMD" ]; then
        printf "Exiting: htpasswd is missing. Install: apt install apache2-utils\n"
        exit 1
    fi

    if [ -z "$USERNAME" ]; then
        usage
    fi
}

check_config "$USERNAME"
printf "Generating Bcrypt hash for username: %s\n\n" "$USERNAME"
$CMD $OPTS "$USERNAME"
exit $?
