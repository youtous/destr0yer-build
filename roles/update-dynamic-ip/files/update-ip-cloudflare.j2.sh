#!/bin/bash

# script from https://gist.github.com/benkulbertis/fff10759c2391b6618dd

# CHANGE THESE
auth_email="{{ update_ip_cloudflare_email }}"
auth_key="{{ update_ip_cloudflare_auth_key }}" # found in cloudflare account settings
zone_name="{{ update_ip_cloudflare_zone_name }}"
record_name="{{ update_ip_cloudflare_record_name }}"

{% if update_ip_protocol == 'ipv6' %}
public_ipv6=$(dig TXT +short whoami.cloudflare.com @ns1.cloudflare.com -6)
ip=$public_ipv6
{% else %}
public_ipv4=$(dig TXT +short whoami.cloudflare.com @ns1.cloudflare.com -4)
ip=$public_ipv4
{% endif %}

ip_file="ip.txt"
id_file="{{ update_ip_ids_file }}"
log_file="{{ update_ip_log_file }}"

# LOGGER
log() {
    if [ "$1" ]; then
        echo -e "[$(date)] - $1" >> $log_file
    fi
}

# SCRIPT START
log "Check Initiated"

if [ -f $ip_file ]; then
    old_ip=$(cat $ip_file)
    if [ $ip == $old_ip ]; then
        echo "IP has not changed."
        exit 0
    fi
fi

if [ -f $id_file ] && [ $(wc -l $id_file | cut -d " " -f 1) == 2 ]; then
    zone_identifier=$(head -1 $id_file)
    record_identifier=$(tail -1 $id_file)
else
    zone_identifier=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$zone_name" -H "X-Auth-Email: $auth_email" -H "X-Auth-Key: $auth_key" -H "Content-Type: application/json" | grep -Po '(?<="id":")[^"]*' | head -1 )
    record_identifier=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_identifier/dns_records?name=$record_name" -H "X-Auth-Email: $auth_email" -H "X-Auth-Key: $auth_key" -H "Content-Type: application/json"  | grep -Po '(?<="id":")[^"]*')
    echo "$zone_identifier" > $id_file
    echo "$record_identifier" >> $id_file
    # keep the file private
    chmod 0600 $id_file
fi

update=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$zone_identifier/dns_records/$record_identifier" -H "X-Auth-Email: $auth_email" -H "X-Auth-Key: $auth_key" -H "Content-Type: application/json" --data "{\"id\":\"$zone_identifier\",\"type\":\"A\",\"name\":\"$record_name\",\"content\":\"$ip\"}")

if [[ $update == *"\"success\":false"* ]]; then
    message="API UPDATE FAILED. DUMPING RESULTS:\n$update"
    log "$message"
    echo -e "$message"
    exit 1
else
    message="IP changed to: $ip"
    echo "$ip" > $ip_file
    log "$message"
    echo "$message"
fi
