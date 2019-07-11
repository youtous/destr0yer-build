#!/usr/bin/env ruby
# This script save a list of docker volumes to a path given as argument

if ARGV.empty?
  puts "[#{Time.now}] Error ! No output path given."
  exit
end
save_path = ARGV[0]

puts "[#{Time.now}] Saving docker volumes to #{save_path}"

File.readlines(__dir__ + '/docker-volumes.txt').each do |docker_volume|
  docker_volume = docker_volume.strip
  unless system( "docker volume inspect #{docker_volume}" )
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

  command = "docker run -v #{docker_volume}:/volume --rm loomchild/volume-backup backup - > #{save_path}/#{docker_volume}.taz.bz2"
  puts "[#{Time.now}] Executing backup... \n#{command}"
  output = `#{command}`
  puts "[#{Time.now}] #{output}"

  puts "[#{Time.now}] Unpause paused containers."
  containers_ids.each do |id|
    `docker unpause #{id}`
  end
end

puts "[#{Time.now}] All docker volumes has been successfully saved!"
