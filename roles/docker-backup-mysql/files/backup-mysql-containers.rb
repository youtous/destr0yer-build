#!/usr/bin/env ruby
# This script save a list of mysql docker container to a path given as argument (uses mysqldump)
require 'set'

if ARGV.empty?
  puts "[#{Time.now}] Error ! No output path given."
  exit
end
save_path = ARGV[0]

puts "[#{Time.now}] Saving mysql docker containers to #{save_path}"

# list containers
# from files
files_list = Set.new([__dir__ + '/docker-mysql-containers.txt'])
files_list.merge(Dir.glob(__dir__ + "/backup.d/*.txt"))
puts "[#{Time.now}] Sourcing containers list from #{files_list}..."

list_containers = Set.new([])
files_list.each do |path|
  File.readlines(path).each do |container_name|
    list_containers.add(container_name.strip)
  end
end


list_containers.each do |docker_container|
  container_id = `docker ps -aq --filter name=#{docker_container}`.strip

  if container_id.empty?
    puts "[#{Time.now}] Docker container \"#{docker_container}\" not found."
    next
  end

  puts "[#{Time.now}] Saving mysql docker container: #{docker_container}"

  # from https://gist.github.com/saniaky/30985d144374b09bf5118dad52d721fa
  command = "docker exec #{container_id} sh -c 'mysqldump --all-databases --quick --single-transaction --skip-lock-tables --flush-privileges -uroot -p\"$MYSQL_ROOT_PASSWORD\"' > #{save_path}/all_databases_#{docker_container}.sql"

  puts "[#{Time.now}] Executing backup... \n#{command}"
  output = `#{command}`
  puts "[#{Time.now}] #{output}"
end

puts "[#{Time.now}] All mysql docker containers has been successfully saved!"
