#!/usr/bin/env python3
"""Check, then explicitly migrate an existing EKS API to private-only access.

Run from the cluster VPC or a routed private network. No changes by default.
This is an operator migration, not a second Terraform owner of Omnistrate's EKS.
"""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
from urllib.parse import urlparse


def proxy_environment():
    return {key: value for key, value in os.environ.items()
            if key.lower() in {'http_proxy', 'https_proxy', 'all_proxy', 'no_proxy'}}


def run(args):
    # The Kubernetes API checks must prove direct private connectivity. AWS
    # management calls retain their normal environment (including any proxy).
    env = None
    if args[0] == 'kubectl':
        env = {key: value for key, value in os.environ.items()
               if key not in proxy_environment()}
    return subprocess.check_output(args, text=True, timeout=90, env=env).strip()


def require_private_dns(endpoint):
    host = urlparse(endpoint).hostname
    if not host:
        raise RuntimeError('Invalid cluster endpoint')
    addresses = {item[4][0] for item in socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)}
    networks = [ipaddress.ip_network(cidr) for cidr in
                ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', 'fc00::/7')]
    if not addresses or any(not any(ipaddress.ip_address(a) in n for n in networks)
                            for a in addresses):
        raise RuntimeError('Endpoint must resolve exclusively to private VPC addresses. '
                           'Run from the VPC or a correctly routed private network.')


def migrate(args):
    aws = ['aws', '--profile', args.profile, '--region', args.region, '--no-cli-pager']
    account = json.loads(run(aws + ['sts', 'get-caller-identity']))['Account']
    if account != args.account:
        raise RuntimeError('AWS account does not match --account')
    describe = aws + ['eks', 'describe-cluster', '--name', args.cluster]
    cluster = json.loads(run(describe))['cluster']
    if cluster['status'] != 'ACTIVE':
        raise RuntimeError('Cluster must be ACTIVE')
    old = cluster['resourcesVpcConfig']
    if not old['endpointPrivateAccess']:
        raise RuntimeError('Enable and validate private endpoint access in a separate change first')
    require_private_dns(cluster['endpoint'])
    # Build a temporary, cluster-pinned config; never modify the operator's config.
    with tempfile.TemporaryDirectory(prefix='eks-private-preflight-') as tmp:
        config = Path(tmp) / 'config.json'
        config.write_text(json.dumps({
            'apiVersion': 'v1', 'kind': 'Config', 'current-context': 'target',
            'clusters': [{'name': 'target', 'cluster': {
                'server': cluster['endpoint'],
                'certificate-authority-data': cluster['certificateAuthority']['data']}}],
            'contexts': [{'name': 'target', 'context': {'cluster': 'target', 'user': 'target'}}],
            'users': [{'name': 'target', 'user': {'exec': {
                'apiVersion': 'client.authentication.k8s.io/v1beta1', 'command': 'aws',
                'args': ['--profile', args.profile, '--region', args.region, 'eks',
                         'get-token', '--cluster-name', args.cluster],
                # Restore proxies only for the AWS token helper, not kubectl.
                'env': [{'name': key, 'value': value}
                        for key, value in proxy_environment().items()],
                'interactiveMode': 'Never'}}}]}))
        config.chmod(0o600)
        kubectl = ['kubectl', '--kubeconfig', str(config), '--request-timeout=30s']
        if run(kubectl + ['get', '--raw=/readyz']) != 'ok':
            raise RuntimeError('Private API readiness check failed')
        if run(kubectl + ['auth', 'can-i', 'get', 'nodes']) != 'yes':
            raise RuntimeError('Operator cannot read cluster nodes')
        print('Private DNS, authenticated API readiness, and node-read authorization verified.')
        if not old['endpointPublicAccess']:
            print('Already private-only; no change required.')
            return
        if not args.apply:
            print('CHECK ONLY: public access remains unchanged. Review every CI/operator path before --apply.')
            return
        if not args.access_paths_reviewed or not args.snapshot:
            raise RuntimeError('--apply requires --access-paths-reviewed and a new --snapshot path')
        snapshot = {'account': account, 'region': args.region, 'cluster': args.cluster,
                    'before': {k: old[k] for k in ('endpointPrivateAccess', 'endpointPublicAccess', 'publicAccessCidrs')},
                    'capturedAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
        # Exclusive creation prevents overwriting the original rollback values on reruns.
        fd = os.open(args.snapshot, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as handle:
            json.dump(snapshot, handle, indent=2)
        update = json.loads(run(aws + ['eks', 'update-cluster-config', '--name', args.cluster,
            '--resources-vpc-config', 'endpointPrivateAccess=true,endpointPublicAccess=false']))['update']['id']
        print(f'Update submitted: {update}. Original settings saved to {args.snapshot}.')
        for _ in range(120):
            result = json.loads(run(aws + ['eks', 'describe-update', '--name', args.cluster,
                                         '--update-id', update]))['update']
            if result['status'] == 'Successful':
                break
            if result['status'] != 'InProgress':
                raise RuntimeError(f'Update ended with {result["status"]}; inspect AWS update details')
            time.sleep(10)
        else:
            raise RuntimeError('Update still pending after 20 minutes; inspect before retrying')
        current = json.loads(run(describe))['cluster']['resourcesVpcConfig']
        if current['endpointPublicAccess'] or not current['endpointPrivateAccess']:
            raise RuntimeError('Post-change endpoint settings do not match requested state')
        require_private_dns(cluster['endpoint'])
        if run(kubectl + ['get', '--raw=/readyz']) != 'ok':
            raise RuntimeError('Post-change private API check failed; use documented rollback if required')
        print('Verified: public API disabled, private API enabled and reachable. Run deployment smoke checks next.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('profile', 'region', 'account', 'cluster'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--access-paths-reviewed', action='store_true',
                        help='Attest that all CI, Terraform, Omnistrate and operator access paths were validated')
    parser.add_argument('--snapshot', help='New file for original endpoint settings; required with --apply')
    migrate(parser.parse_args())


if __name__ == '__main__':
    main()
