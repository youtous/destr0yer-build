#!/bin/sh
# from https://unix.stackexchange.com/questions/307994/compute-bcrypt-hash-from-command-line

## bcrypt passwd generator ##
#############################
CMD=$(which htpasswd 2>/dev/null)
OPTS="-nBC 15"
USERNAME=$1

usage() {
        local script=$(basename $0)
        cat <<EOF
$script: Generate Bcrypt Hashed Passwords using htpasswd

Usage: $script username
EOF
        exit 1
}

check_config() {
    if [ -z $CMD ]; then
        printf "Exiting: htpasswd is missing.\n"
        exit 1
    fi

    if [ -z "$USERNAME" ]; then
            usage
    fi
}

check_config $USERNAME
printf "Generating Bcrypt hash for username: $USERNAME\n\n"
$CMD $OPTS $USERNAME
exit $?