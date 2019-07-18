#!/usr/bin/env bash
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
function include() {
    for FILE in $( find "$1" -type f -print | sort )
    do
        source ${FILE}
    done
}

# include pre scripts
include ${DIR}/pre.d/*.sh