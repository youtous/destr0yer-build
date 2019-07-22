#!/usr/bin/env bash
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
function include() {
    for FILE in `ls $1 | sort`
    do
        source ${FILE}
    done
}

# include post scripts
include "${DIR}/post.d/*.sh"
