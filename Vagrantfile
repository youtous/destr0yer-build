# -*- mode: ruby -*-
# vi: set ft=ruby :

VAGRANTFILE_API_VERSION = "2"

# {FIX} In order to have Virtualbox Guest Additions synced with the host, install
# vagrant plugin install vagrant-vbguest
servers=[
    {
        :hostname => "heaven-pascal.youtous.dv",
        :ipv4 => "192.168.100.10",
        :ipv6 => "fde4:8dba:82e1::c1",
        :box => "debian/bookworm64",
        :ram => 4096,
        :cpu => 2
    },
    {
        :hostname => "heaven-roberval.youtous.dv",
        :ipv4 => "192.168.100.11",
        :ipv6 => "fde4:8dba:82e1::c2",
        :box => "debian/bookworm64",
		:ram => 4096,
        :cpu => 2
    }
]

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|
    # manage hosts file https://github.com/devopsgroup-io/vagrant-hostmanager
    #config.hostmanager.enabled = true
    # each vm will have his /etc/hosts updated, run  `vagrant hostmanager` to manually update
    #config.hostmanager.manage_guest = false
    # do not modify hosts on host
    #config.hostmanager.manage_host = false

	config.vagrant.plugins = ["vagrant-vbguest"]
	if Vagrant.has_plugin?("vagrant-vbguest") then
		config.vbguest.auto_update = false
	end
	# workaround for vbguest plugin
	config.vbguest.installer_options = { allow_kernel_upgrade: true }
	config.vbguest.installer_hooks[:before_install] = [
		"apt-get update",
		"apt-get -y install libxt6 libxmu6"
	]
	config.vbguest.installer_hooks[:after_install] = [
		"VBoxClient --version"
	]

	servers.each do |machine|
		config.vm.define machine[:hostname] do |node|

			# define the VM
			node.vm.box = machine[:box]
			node.vm.box_version = machine[:box_version]

			# configure network
			# enable ipv6
			node.vm.provision :shell, inline: "sed -i 's/net.ipv6.conf.all.disable_ipv6 = 1/net.ipv6.conf.all.disable_ipv6 = 0/g' /etc/sysctl.conf"
			# ensure eth0 is auto enabled
			node.vm.provision :shell, inline: "echo 'auto eth0' > /etc/network/interfaces.d/eth0"
			node.vm.hostname = machine[:hostname]
			node.vm.network :private_network, ip: machine[:ipv4], auto_config: true
			node.vm.network :private_network, ip: machine[:ipv6], auto_config: true

			node.vm.provider :virtualbox do |vb|
				vb.customize ["modifyvm", :id, "--memory", machine[:ram]]
				vb.customize ["modifyvm", :id, "--cpus", machine[:cpu]]
   				vb.customize ["modifyvm", :id, "--ioapic", "on"]
   				vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
   				vb.customize ["modifyvm", :id, "--natdnsproxy1", "on"]
			end

			# register ssh keys
			node.vm.provision "shell" do |s|
    				ssh_pub_key = File.readlines("#{Dir.home}/.ssh/id_ed25519.pub").first.strip
    				s.inline = <<-SHELL
    				    echo #{ssh_pub_key} >> /home/vagrant/.ssh/authorized_keys
    				    mkdir -p /root/.ssh/
    				    echo #{ssh_pub_key} >> /root/.ssh/authorized_keys
    				SHELL
     		end

			node.vm.synced_folder '.', '/vagrant', disabled: true
		end
    end
end
