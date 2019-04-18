#!/usr/bin/env bash

export PATH="${PATH:+$PATH:}/bin:/usr/bin:/usr/local/bin"

[ -r /etc/lsb-release ] && . /etc/lsb-release
if [ -z "$DISTRIB_DESCRIPTION" ] && [ -x /usr/bin/lsb_release ]; then
	# Fall back to using the very slow lsb_release utility
	DISTRIB_DESCRIPTION=$(lsb_release -s -d)
fi

date=`date`
load=`cat /proc/loadavg | awk '{print $1}'`
root_usage=`df -h / | awk '/\// {print $(NF-1)}'`
memory_usage=`free -m | awk '/Mem:/ { total=$2 } /buffers\/cache/ { used=$3 } END { printf("%3.1f%%", used/total*100)}'`
swap_usage=`free -m | awk '/Swap/ { printf("%3.1f%%", "exit !$2;$3/$2*100") }'`
users=`users | wc -w`
time=`uptime | grep -ohe 'up .*' | sed 's/,/\ hours/g' | awk '{ printf $2" "$3 }'`
processes=`ps aux | wc -l`
public_ip=$(dig TXT +short o-o.myaddr.l.google.com @ns1.google.com)

KERNEL_VERSION=$(uname -r)
if [[ $KERNEL_VERSION =~ ^3\.2\.[35][24].* ]]; then
    KERNEL_TITLE="- Marvell"
fi

[ -f /etc/motd.head ] && cat /etc/motd.head || true
printf "\n"
printf "Welcome on %s (%s %s %s %s)\n" "${IMAGE_DESCRIPTION}" "$(uname -o)" "${KERNEL_VERSION}" "$(uname -m)" "$KERNEL_TITLE"
printf "\n"
printf "System information as of: %s\n" "$date"
printf "\n"
printf "System load:\t%s\t\tSystem uptime:\t%s\n" "$load" "$time"
printf "Memory usage:\t%s\n" $memory_usage
printf "Usage on /:\t%s\t\tSwap usage:\t%s\n" $root_usage $swap_usage
printf "Local Users:\t%s\t\tProcesses:\t%s\n" $users $processes
printf "Pub IP Address:\t%s\n" $public_ip
printf "_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-\n"
# volumes info
timeout --signal=kill 2s df -h | grep -E "^(/dev/|Filesystem)"

printf "\n"
[ -f /etc/motd.tail ] && cat /etc/motd.tail || true