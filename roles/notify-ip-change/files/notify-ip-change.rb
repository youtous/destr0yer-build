#!/usr/bin/env ruby
# This script check if ip has changed, then notify
require 'json'

IPS_FILE = __dir__ + '/host-ips.json'

if ARGV.empty?
  abort("Error ! No email alert given.")
end
email_alert = ARGV[0]

puts "[#{Time.now}] Checking ips of current host"

# get IPv4, redirect potential network error to /dev/null
command_public_ipv4 = "dig CH TXT whoami.cloudflare @1.1.1.1 +short -4 2> /dev/null"
puts "[#{Time.now}] Executing command: #{command_public_ipv4}"
public_ipv4 = `#{command_public_ipv4}`.to_s.strip.gsub('"', "")
if not $?.success?
  puts "[#{Time.now}] Could not determine IPv4"
  public_ipv4 = ""
end
puts "[#{Time.now}] Current IPv4: #{public_ipv4}"

# get IPPv6
command_public_ipv6 = "ip -6 addr | grep inet6 | grep -Poi '(?<=inet6\s).*(?=\sscope global)'"
puts "[#{Time.now}] Executing command: #{command_public_ipv6}"
public_ipv6 = `#{command_public_ipv6}`.to_s.strip.gsub('"', "")
if not $?.success?
  puts "[#{Time.now}] Could not determine IPv6"
  public_ipv6 = ""
end
puts "[#{Time.now}] Current IPv6: #{public_ipv6}"

# struct to save
ips = {
    'ipv4' => public_ipv4,
    'ipv6' => public_ipv6,
}

if File.file?(IPS_FILE)
  content = File.open(IPS_FILE)
  old_ips = JSON.load(content)

  # check not failed update ips
  failed_get_ipv4 = !old_ips['ipv4'].empty? && ips['ipv4'].empty?
  failed_get_ipv6 = !old_ips['ipv6'].empty? && ips['ipv6'].empty?

  # check any change
  if (old_ips['ipv4'] != ips['ipv4'] && !failed_get_ipv4) ||
      (old_ips['ipv6'] != ips['ipv6'] && !failed_get_ipv6)
    puts "[#{Time.now}] Ip changed detected. Sending email alert."

    # notify change by email
    to = email_alert
    hostname = `hostname`.strip
    subject = "[#{hostname}] IP change detected"
    content = "IPv4: #{ips["ipv4"]} (old: #{old_ips["ipv4"]})
IPv6: #{ips["ipv6"]} (old: #{old_ips["ipv6"]})"
    mail_command = "mail -s \"#{subject}\" #{to}<<EOF
#{content}
EOF"

    puts "[#{Time.now}] Executing command: #{mail_command}"
    `#{mail_command}`

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
