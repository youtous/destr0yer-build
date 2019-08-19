#!/usr/bin/env ruby
# This script save a list of docker volumes to a path given as argument
require 'set'

if ARGV.empty?
  abort "Error ! No output path given."
end
save_path = ARGV[0]

puts "[#{Time.now}] Saving docker volumes to #{save_path}"

# list containers
# from files
files_list = Set.new([__dir__ + '/docker-volumes.txt'])
files_list.merge(Dir.glob(__dir__ + "/backup.d/*.txt"))
puts "[#{Time.now}] Sourcing containers list from #{files_list}..."

list_containers = Set.new([])
files_list.each do |path|
  File.readlines(path).each do |container_name|
    list_containers.add(container_name.strip)
  end
end

list_containers.each do |docker_volume|
  unless system("docker volume inspect #{docker_volume}")
    puts "[#{Time.now}] Docker volume \"#{docker_volume}\" not found."
    next
  end

  puts "[#{Time.now}] Saving docker volume: #{docker_volume}"

  # stop all other containers using this volume
  containers_ids = `docker ps -aq --filter volume=#{docker_volume}`.split("\n")
  puts "[#{Time.now}] Containers #{containers_ids} have to be paused. Processing..."
  containers_ids.each do |id|
    `docker pause #{id}`
  end

  command = "docker run -v #{docker_volume}:/volume --log-driver none --rm loomchild/volume-backup backup -c none - > #{save_path}/#{docker_volume}.tar"
  puts "[#{Time.now}] Executing backup... \n#{command}"
  output = `#{command}`
  puts "[#{Time.now}] #{output}"

  puts "[#{Time.now}] Unpause paused containers."
  containers_ids.each do |id|
    `docker unpause #{id}`
  end
end

puts "[#{Time.now}] All docker volumes has been successfully saved!"
