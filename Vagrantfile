# -*- mode: ruby -*-
# vi: set ft=ruby :

VAGRANTFILE_API_VERSION = "2"

# Dev SSH key — generated via `just ssh-keygen`, stored in workspace
DEV_KEY_PATH = File.join(__dir__, ".dev", "id_ed25519.pub")

# Dedicated network for the dev cluster (reachable from devcontainer via --network=host)
DEV_NETWORK = "192.168.56"

servers = [
    {
        :hostname => "ctrl.k3s.dev.local",
        :ipv4 => "#{DEV_NETWORK}.10",
        :box => "debian/trixie64",
        :ram => 5632,
        :cpu => 2,
        :extra_disks => [{:size => '20G'}]  # btrfs backup volume (/dev/vdb)
    },
    {
        :hostname => "worker.k3s.dev.local",
        :ipv4 => "#{DEV_NETWORK}.11",
        :box => "debian/trixie64",
        :ram => 5632,
        :cpu => 2
    }
]

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|

    servers.each do |machine|
        config.vm.define machine[:hostname] do |node|
            node.vm.box = machine[:box]
            node.vm.hostname = machine[:hostname]

            # Network: libvirt private network (accessible from host and --network=host containers)
            node.vm.network :private_network, ip: machine[:ipv4]

            # Libvirt/KVM provider
            node.vm.provider :libvirt do |lv|
                lv.memory = machine[:ram]
                lv.cpus = machine[:cpu]
                lv.driver = "kvm"
                lv.default_prefix = "destr0yer_"

                (machine[:extra_disks] || []).each do |disk|
                    lv.storage :file, :size => disk[:size], :type => 'raw', :bus => 'virtio'
                end
            end

            # Register the dev SSH key (generated via `just ssh-keygen`)
            node.vm.provision "shell" do |s|
                if File.exist?(DEV_KEY_PATH)
                    ssh_pub_key = File.readlines(DEV_KEY_PATH).first.strip
                else
                    abort "Dev SSH key not found at #{DEV_KEY_PATH}. Run `just ssh-keygen` first."
                end
                s.inline = <<-SHELL
                    echo #{ssh_pub_key} >> /home/vagrant/.ssh/authorized_keys
                    mkdir -p /root/.ssh/
                    echo #{ssh_pub_key} >> /root/.ssh/authorized_keys
                SHELL
            end

            node.vm.synced_folder '.', '/vagrant', disabled: true

            # Clean up extra disk volumes on destroy (vagrant-libvirt doesn't do this automatically)
            node.trigger.before :destroy do |trigger|
                trigger.name = "Clean up extra disk volumes"
                trigger.ruby do |env, machine|
                    (machine_cfg = servers.find { |s| s[:hostname] == machine.name.to_s }) || next
                    (machine_cfg[:extra_disks] || []).each_with_index do |_disk, idx|
                        vol_name = "destr0yer_#{machine.name}-vd#{('b'.ord + idx).chr}.raw"
                        system("sudo virsh vol-delete --pool default #{vol_name} 2>/dev/null")
                    end
                end
            end
        end
    end
end
