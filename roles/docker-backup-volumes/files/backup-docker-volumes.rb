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
  puts "[#{Time.now}] Saving docker volume: #{docker_volume}"
  command = "docker run -v #{docker_volume}:/volume --rm loomchild/volume-backup backup - > #{save_path}/#{docker_volume}.taz.bz2"
  puts "[#{Time.now}] Executing backup... \n#{command}"
  output = `#{command}`
  puts "[#{Time.now}] #{output}"
end

puts "[#{Time.now}] All docker volumes has been successfully saved!"
