#!/bin/bash

echo "Usage: source this script, then use --token=\$K8S_AUTH_API_KEY in your commands"
echo "Please enter your k8s token : "
read -sr K8S_AUTH_API_KEY
export K8S_AUTH_API_KEY=$K8S_AUTH_API_KEY
