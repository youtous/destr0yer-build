# -*- mode: ruby -*-
# vi: set ft=ruby :

VAGRANTFILE_API_VERSION = "2"

servers=[
    {
        :hostname => "heaven-pascal.youtous.dv",
        :ip => "192.168.100.10",
        :box => "generic/debian9",
        :ram => 2048,
        :cpu => 2
    },
    {
        :hostname => "heaven-roberval.youtous.dv",
        :ip => "192.168.100.11",
        :box => "generic/debian9",
        :ram => 2048,
        :cpu => 2
    }
]

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|
    # manage hosts file https://github.com/devopsgroup-io/vagrant-hostmanager
    config.hostmanager.enabled = true
    # each vm will have his /etc/hosts updated, run  `vagrant hostmanager` to manually update
    config.hostmanager.manage_guest = true
    # do not modify hosts on host
    config.hostmanager.manage_host = false

	servers.each do |machine|
		config.vm.define machine[:hostname] do |node|
			
			# define the VM
			node.vm.box = machine[:box]
			node.vm.hostname = machine[:hostname]
			node.vm.network :private_network, ip: machine[:ip]

			node.vm.provider :virtualbox do |vb|
				vb.customize ["modifyvm", :id, "--memory", machine[:ram]]
				vb.customize ["modifyvm", :id, "--cpus", machine[:cpu]]
   				vb.customize ["modifyvm", :id, "--ioapic", "on"]
   				vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
   				vb.customize ["modifyvm", :id, "--natdnsproxy1", "on"]
			end
		
			# register ssh keys	
			node.vm.provision "shell" do |s|
    				ssh_pub_key = File.readlines("#{Dir.home}/.ssh/id_rsa.pub").first.strip
    				s.inline = <<-SHELL
    				    echo #{ssh_pub_key} >> /home/vagrant/.ssh/authorized_keys
    				    mkdir -p /root/.ssh/
    				    echo #{ssh_pub_key} >> /root/.ssh/authorized_keys
    				SHELL
     		end
		end
    end
end

 
