#!/usr/bin/env bash

# This script is a workaround for docker-swarm fixed ip.
# Due to the lack the fixed-ip service/container feature, the mailserver must resolve resolver service ip and update its
# /etc/resolv.conf

echo "Starting resolver service updater"

# install dig if missing
apt update && apt -y install --no-install-recommends dnsutils || exit 1

while true; do
  resolver_ip=`dig +short resolver 2>/dev/null`

  if [[ -n "${resolver_ip}" ]] && ! [[ "${resolver_ip}" =~ ^;.* ]]; then
    # gather previous ip in resolv.conf
    starting_ip=`echo "${resolver_ip}" | awk -F. {'print $1'}`
    previous_ip=`grep -Po "^(?:nameserver\\s+)${starting_ip}\\.(.*)" /etc/resolv.conf | awk {'print $2'}`

    # if ip !=
    if [ "$previous_ip" != "$resolver_ip" ]; then
      echo "Resolver service ip changed (from: ${previous_ip}, to: ${resolver_ip}), updating..."
      cp /etc/resolv.conf /etc/resolv.conf.new
      if [ -n "${previous_ip}" ]; then
        # delete previous entry
        sed -i "/nameserver ${previous_ip}/d" /etc/resolv.conf.new
      fi
      # prepend new nameserver
      sed -i "1s;^;nameserver ${resolver_ip}\n;" /etc/resolv.conf.new
      cp /etc/resolv.conf.new /etc/resolv.conf

      # restart postfix if running
      if supervisorctl status postfix | grep -q 'RUNNING'; then
        supervisorctl restart postfix
      fi
      # restart dovecot if running
      if supervisorctl status dovecot | grep -q 'RUNNING'; then
        supervisorctl restart dovecot
      fi
    fi
  else
    echo "Resolver not yet ready... waiting 10 seconds"
  fi

   # check changes every 10 secs
   sleep 10
done


exit 0