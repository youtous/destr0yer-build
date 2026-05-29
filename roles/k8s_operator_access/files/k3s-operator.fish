# Ansible managed — deployed by k8s_operator_access role (K3S nodes only)

set -gx KUBECONFIG ~/.kube/operator.yaml

function __breakglass_run --description "Run a command with the admin kubeconfig (sudo cat, execute as user)"
    set -l tmpkc (mktemp /tmp/breakglass-kubeconfig.XXXXXX)
    if not sudo cat /etc/rancher/k3s/k3s.yaml > $tmpkc 2>/dev/null
        echo "Failed to read admin kubeconfig. sudo access required." >&2
        rm -f $tmpkc
        return 1
    end
    chmod 600 $tmpkc
    echo "--- BREAK-GLASS: using admin kubeconfig (system:masters) ---" >&2
    KUBECONFIG=$tmpkc command $argv
    set -l rc $status
    rm -f $tmpkc
    return $rc
end

function breakglass-kubectl --description "Emergency kubectl with admin kubeconfig"
    __breakglass_run kubectl $argv
end

function breakglass-k9s --description "Emergency k9s with admin kubeconfig"
    __breakglass_run k9s $argv
end

if status is-interactive
    echo "K3S operator: KUBECONFIG=~/.kube/operator.yaml"
    echo "  Break-glass: breakglass-kubectl / breakglass-k9s"
end
