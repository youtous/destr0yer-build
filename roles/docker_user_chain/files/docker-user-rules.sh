#!/bin/bash

# This script is restoring saved DOCKER-USER iptables rules

if [ -f /etc/iptables.docker-user.rules.v4 ]; then
    # replace create chain by flushing it
    sed -i 's/-N DOCKER-USER/-F DOCKER-USER/g' /etc/iptables.docker-user.rules.v4

    /sbin/iptables-restore -n < /etc/iptables.docker-user.rules.v4
fi

if [ -f /etc/iptables.docker-user.rules.v6 ]; then
      # replace create chain by flushing it
    sed -i 's/-N DOCKER-USER/-F DOCKER-USER/g' /etc/iptables.docker-user.rules.v4

    /sbin/ip6tables-restore -n < /etc/iptables.docker-user.rules.v6
fi
