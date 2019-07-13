#!/usr/bin/env ruby
# This script helps to generate X509 certificates.
# First, it will generate a CertificateAuthority if it does not exists.
# Then client certificates will be generated.
#
# Details can be found in README.md file.

# where to save certificates
SAVE_PATH = 'certs/'
# validity of the RootCA certificate in days
ROOT_CA_VALIDITY = 2500
# validity of the client certificate in days
CLIENT_VALIDITY = 1024

def select_root_ca
  puts "~> Please select which RootCA you want to use for generating client certificates:"
  root_certificates = Dir.glob("#{SAVE_PATH}*-rootCA.crt")
  puts "[-1] Create a new Root CA"
  root_certificates.each_with_index {|key, index| puts "[#{index}] #{key.sub(SAVE_PATH, '')}"}
  id = gets.chomp.to_i

  if id == -1
    puts "~> Generating a new RootCA..."

    puts "Please indicate a name for the RootCA:"
    name = gets.chomp

    # check the RootCA does not exists
    if File.file?("#{SAVE_PATH}#{name}.key")
      puts "ERROR! Selected RootCA already exists. Please delete it manually in order to continue."
      return select_root_ca
    end

    # private key
    unless system "openssl genrsa -chacha20 -out #{SAVE_PATH}#{name}-rootCA.key 4096"
      File.delete("#{SAVE_PATH}#{name}-rootCA.key") if File.exists? "#{SAVE_PATH}#{name}-rootCA.key"
      raise "Could not generate RootCA private key."
    end
    puts "RootCA RSA private key (4096 bit) generated using chacha20. [#{name}-rootCA.key]"

    unless system "openssl req -x509 -new -nodes -key #{SAVE_PATH}#{name}-rootCA.key -sha256 -days #{ROOT_CA_VALIDITY} -out #{SAVE_PATH}#{name}-rootCA.crt"
      File.delete("#{SAVE_PATH}#{name}-rootCA.crt") if File.exists? "#{SAVE_PATH}#{name}-rootCA.crt"
      raise "Could not generate RootCA public certificate."
    end
    puts "RootCA public certificate (crt) generated using x509 standard (hashed with sha256). Certificate is valid for #{ROOT_CA_VALIDITY} days. [#{name}-rootCA.crt]"
    return "#{name}-rootCA"
  elsif root_certificates[id].nil?
    puts "ERROR! Wrong index selected"
    return select_root_ca
  else
    return root_certificates[id].sub('.crt', '').sub(SAVE_PATH, '')
  end
end

# begin script
puts "~> Generation of X509 certificates."
puts "Certificates will be output in '#{SAVE_PATH}' directory"

root_ca = select_root_ca
puts "~> RootCA #{root_ca} selected"
puts "~> Generating a new client certificate (to be deployed)"
puts "Please indicate a name for the client certificate:"
name = gets.chomp

# private key
unless system "openssl genrsa -chacha20 -out #{SAVE_PATH}#{name}.key 4096"
  File.delete("#{SAVE_PATH}#{name}.key") if File.exists? "#{SAVE_PATH}#{name}.key"
  raise "Could not generate client private key."
end
puts "Client RSA private key (4096 bit) generated using chacha20. [#{name}.key]"

# certificate signature request
unless system "openssl req -new -key #{SAVE_PATH}#{name}.key -out #{SAVE_PATH}#{name}.csr"
  File.delete("#{SAVE_PATH}#{name}.csr") if File.exists? "#{SAVE_PATH}#{name}.csr"
  raise "Could not generate client certificate key."
end
puts "Client Certificate Signing Request containing information for RootCA signature has been generated. [#{name}.csr]"

# signing client certificate using RootCA private key
# first, we need to check if a serial has been created
if File.file?("#{SAVE_PATH}#{root_ca}.srl")
  serial_argument = "-CAserial #{SAVE_PATH}#{root_ca}.srl"
else
  serial_argument = "-CAcreateserial"
end

unless system "openssl x509 -req -in #{SAVE_PATH}#{name}.csr -CA #{SAVE_PATH}#{root_ca}.crt -CAkey #{SAVE_PATH}#{root_ca}.key #{serial_argument} -out #{SAVE_PATH}#{name}.crt -days #{CLIENT_VALIDITY} -sha256"
  File.delete("#{SAVE_PATH}#{name}.crt") if File.exists? "#{SAVE_PATH}#{name}.crt"
  raise "Could not sign client certificate."
end
puts "Client public certificate (.crt) has been signed by RootCA using x509 standard (hashed with sha256). Certificate is valid for #{CLIENT_VALIDITY} days. [#{name}.crt]"

