#!/usr/bin/env ruby
# This script check if ip has changed, then notify
require 'json'

IPS_FILE = __dir__ + '/host-ips.json'

if ARGV.empty?
  abort("Error ! No email alert given.")
end
email_alert = ARGV[0]

puts "[#{Time.now}] Checking ips of current host"

# get IPv4
command_public_ipv4 = "dig -4 TXT +short whoami.cloudflare.com @ns1.cloudflare.com -4"
puts "[#{Time.now}] #{command_public_ipv4}"
public_ipv4 = `#{command_public_ipv4}`.strip!.gsub!('"', "")
puts "[#{Time.now}] Current IPv4: #{public_ipv4}"

# get IPPv6
command_public_ipv6 = "ip -6 addr | grep inet6 | grep -Poi '(?<=inet6\s).*(?=\sscope global)'"
puts "[#{Time.now}] #{command_public_ipv6}"
public_ipv6 = `#{command_public_ipv6}`.strip!.gsub!('"', "")
puts "[#{Time.now}] Current IPv6: #{public_ipv6}"

# struct to save
ips = {
    "ipv4" => public_ipv4,
    "ipv6" => public_ipv6,
}

if File.file?(IPS_FILE)
  content = File.open(IPS_FILE)
  old_ips = JSON.load(content)

  # check any change
  if old_ips["ipv4"] != ips["ipv4"] ||
      old_ips["ipv6"] != ips["ipv6"]
    puts "[#{Time.now}] Ip changed detected. Sending email alert."

    # notify change by email
    to = email_alert
    hostname = `hostname`
    subject = "[#{hostname}] IP change detected"
    content = "New ips: \n #{ips} \n\nOld ips: #{old_ips}"
    `mail -s "#{subject}" #{to}<<EOM
  #{content}
EOM`
    # save ips
    File.open(IPS_FILE, "w") do |f|
      f.write(ips.to_json)
    end
  end
else
  puts "[#{Time.now}] Empty ip history. Generating first entry."
  # save ips
  File.open(IPS_FILE, "w") do |f|
    f.write(ips.to_json)
  end
end

puts "[#{Time.now}] Ip check finished."