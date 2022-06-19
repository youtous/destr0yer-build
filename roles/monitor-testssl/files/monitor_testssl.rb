#!/usr/bin/env ruby
# This script check ssl/tls hosts using https://testssl.sh/, a report is send by mail
require 'json'

HOSTS_FILE = __dir__ + '/hosts_list.json'

if ARGV.length != 2
  abort("Error! 2 arguments required: <testssl image name> <report email>")
end
TESTSSL_IMAGE = "#{ARGV[0]}:latest"
EMAIL_REPORT = ARGV[1]

if not File.file?(HOSTS_FILE)
  abort("Error! #{HOSTS_FILE} could not be opened.")
end

puts "[#{Time.now}] Pulling latest testssl image: #{TESTSSL_IMAGE}"
`docker pull #{TESTSSL_IMAGE}`

puts "[#{Time.now}] Checking ssl/tls hosts"
HOSTS_TO_CHECK = JSON.load(File.open(HOSTS_FILE))


HOSTS_TO_CHECK.each do |host|
    puts "[#{Time.now}] Testing host: #{host['host']}"

    protocol_cmd = ""
    if host.key?('protocol')
        protocol_cmd = "--starttls=#{host['protocol']}"
    end

    ipv6_cmd = ""
    if host.key?('ipv6')
        ipv6_cmd = "-6"
    end

    testssl_command = "docker run --rm  --network='host' #{TESTSSL_IMAGE} #{protocol_cmd} #{ipv6_cmd} #{host['host']}"
    puts "[#{Time.now}] Executing command: #{testssl_command}"

    html_report_results = `#{testssl_command} | aha`

    if not $?.success?
      puts "[#{Time.now}] Error while testing host: #{host['host']}"
    end

    report_status = ""
    if html_report_results.downcase.include? "(not ok)"
        report_status = "[NOT OK]"
    end

    # report using email
    to = EMAIL_REPORT
    hostname = `hostname`.strip
    subject = "[#{hostname}] #{report_status} TESTSSL Report - #{host['host']}"
    content = html_report_results
    mail_command = "mail -a 'Content-Type: text/html' -s '#{subject}' #{to}<<EOF
    #{content}
EOF"

    puts "[#{Time.now}] Executing command: #{mail_command}"
    `#{mail_command}`
end

puts "[#{Time.now}] Cleaning pulled testssl image"
`docker rmi #{TESTSSL_IMAGE}`

puts "[#{Time.now}] monitor testssl finished."
