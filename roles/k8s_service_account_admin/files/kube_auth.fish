#!/usr/bin/fish

echo "Usage: source this script, then use --token=\$K8S_AUTH_API_KEY in your commands"
echo "Please enter your k8s token : "
read -s K8S_AUTH_API_KEY
set -x K8S_AUTH_API_KEY "$K8S_AUTH_API_KEY"
