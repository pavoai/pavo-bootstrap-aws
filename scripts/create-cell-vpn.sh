#!/usr/bin/env bash
# Laptop VPN into a cell's VPC (AWS Client VPN, mutual TLS) + cluster-admin for the caller.
# Customer side, cell-account creds. Re-runnable: reuses certs, endpoint and access entry.
# Usage: AWS_PROFILE=<profile> ./scripts/create-cell-vpn.sh <eks-cluster-name> [client-cidr]
set -euo pipefail

cell="${1:?usage: create-cell-vpn.sh <eks-cluster-name> [client-cidr]}"
client_cidr="${2:-10.201.0.0/22}"  # must not overlap the VPC or other VPN profiles
export AWS_REGION="${AWS_REGION:-us-east-1}"

dir="$HOME/pavo-cvpn-$cell"
mkdir -p "$dir" && cd "$dir"
export EASYRSA_PKI="$dir/pki"  # Homebrew's easyrsa otherwise uses /opt/homebrew/etc/easy-rsa/pki

vpc_id="$(aws eks describe-cluster --name "$cell" --query cluster.resourcesVpcConfig.vpcId --output text)"
subnet_id="$(aws eks describe-cluster --name "$cell" --query 'cluster.resourcesVpcConfig.subnetIds[0]' --output text)"
vpc_cidr="$(aws ec2 describe-vpcs --vpc-ids "$vpc_id" --query 'Vpcs[0].CidrBlock' --output text)"

# Certs: one CA signs server + client.
if [ ! -f pki/ca.crt ]; then
  easyrsa init-pki
  EASYRSA_BATCH=1 easyrsa build-ca nopass
  EASYRSA_BATCH=1 easyrsa --san=DNS:server build-server-full server nopass
  EASYRSA_BATCH=1 easyrsa build-client-full client nopass
fi

cvpn="$(aws ec2 describe-client-vpn-endpoints \
  --query "ClientVpnEndpoints[?Status.Code!='deleted' && Status.Code!='deleting' && Tags[?Key=='Name' && Value=='pavo-cvpn-$cell']] | [0].ClientVpnEndpointId" \
  --output text)"
if [ "$cvpn" = None ]; then
  cert_arn="$(aws acm import-certificate \
    --certificate fileb://pki/issued/server.crt \
    --private-key fileb://pki/private/server.key \
    --certificate-chain fileb://pki/ca.crt \
    --tags "Key=Name,Value=pavo-cvpn-$cell" \
    --query CertificateArn --output text)"
  cvpn="$(aws ec2 create-client-vpn-endpoint \
    --vpc-id "$vpc_id" \
    --client-cidr-block "$client_cidr" \
    --server-certificate-arn "$cert_arn" \
    --authentication-options "Type=certificate-authentication,MutualAuthentication={ClientRootCertificateChainArn=$cert_arn}" \
    --connection-log-options Enabled=false \
    --split-tunnel \
    --description "Laptop access to cell $cell" \
    --tag-specifications "ResourceType=client-vpn-endpoint,Tags=[{Key=Name,Value=pavo-cvpn-$cell}]" \
    --query ClientVpnEndpointId --output text)"
  aws ec2 associate-client-vpn-target-network --client-vpn-endpoint-id "$cvpn" --subnet-id "$subnet_id" >/dev/null
  aws ec2 authorize-client-vpn-ingress --client-vpn-endpoint-id "$cvpn" \
    --target-network-cidr "$vpc_cidr" --authorize-all-groups >/dev/null
fi
echo "endpoint $cvpn"

# Cluster-admin for the caller's role (preflight / terraform need it).
role_name="$(aws sts get-caller-identity --query Arn --output text | cut -d/ -f2)"
role_arn="$(aws iam get-role --role-name "$role_name" --query Role.Arn --output text)"
if ! aws eks describe-access-entry --cluster-name "$cell" --principal-arn "$role_arn" >/dev/null 2>&1; then
  aws eks create-access-entry --cluster-name "$cell" --principal-arn "$role_arn" >/dev/null
fi
aws eks associate-access-policy --cluster-name "$cell" --principal-arn "$role_arn" \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster >/dev/null
echo "cluster-admin for $role_arn"

profile="$dir/pavo-$cell.ovpn"
aws ec2 export-client-vpn-client-configuration --client-vpn-endpoint-id "$cvpn" --output text > "$profile"
printf '<cert>\n%s\n</cert>\n<key>\n%s\n</key>\n' \
  "$(openssl x509 -in pki/issued/client.crt)" "$(cat pki/private/client.key)" >> "$profile"

echo "waiting for $cvpn to become available (subnet association, ~5-10 min)"
until [ "$(aws ec2 describe-client-vpn-endpoints --client-vpn-endpoint-ids "$cvpn" \
  --query 'ClientVpnEndpoints[0].Status.Code' --output text)" = available ]; do
  sleep 30
done

cat <<EOF
Ready. AWS VPN Client -> File -> Manage Profiles -> Add Profile -> $profile -> Connect.
Disconnect any other profile routing $vpc_cidr first.
Check: nc -z -G 5 \$(dig +short \$(aws eks describe-cluster --name $cell --query cluster.endpoint --output text | cut -d/ -f3) | head -1) 443
Teardown: aws ec2 disassociate-client-vpn-target-network ... && aws ec2 delete-client-vpn-endpoint --client-vpn-endpoint-id $cvpn
EOF
