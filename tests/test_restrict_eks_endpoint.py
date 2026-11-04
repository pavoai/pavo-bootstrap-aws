import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import json
import tempfile

spec = importlib.util.spec_from_file_location('migration', Path(__file__).resolve().parents[1] / 'scripts' / 'restrict-eks-endpoint.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class MigrationTests(unittest.TestCase):
    def test_kubectl_bypasses_proxies_but_aws_keeps_environment(self):
        env = {'HTTPS_PROXY': 'https://proxy.example:443', 'http_proxy': 'http://proxy.example:80',
               'ALL_PROXY': 'socks5://proxy.example:1080', 'no_proxy': 'localhost',
               'PATH': '/bin', 'AWS_PROFILE': 'test'}
        with patch.dict(m.os.environ, env, clear=True), patch.object(m.subprocess, 'check_output', return_value='ok') as call:
            m.run(['kubectl', 'get', '--raw=/readyz'])
            self.assertEqual(call.call_args.kwargs['env'], {'PATH': '/bin', 'AWS_PROFILE': 'test'})
            m.run(['aws', 'sts', 'get-caller-identity'])
            self.assertIsNone(call.call_args.kwargs['env'])
            self.assertEqual(m.os.environ['HTTPS_PROXY'], env['HTTPS_PROXY'])

    def test_dns_rejects_public_or_mixed_answers(self):
        for addresses in (['8.8.8.8'], ['10.0.0.1', '8.8.8.8'], ['127.0.0.1']):
            with self.subTest(addresses=addresses), patch.object(m.socket, 'getaddrinfo', return_value=[
                    (None, None, None, None, (a, 443)) for a in addresses]):
                with self.assertRaises(RuntimeError):
                    m.require_private_dns('https://example.eks.amazonaws.com')

    def test_dns_accepts_private(self):
        with patch.object(m.socket, 'getaddrinfo', return_value=[(None, None, None, None, ('10.0.0.5', 443))]):
            m.require_private_dns('https://example.eks.amazonaws.com')

    def exercise(self, apply=False, reviewed=False, private=True, account='123', ready='ok'):
        calls = []
        updated = False
        def command(args):
            nonlocal updated
            calls.append(args)
            if 'get-caller-identity' in args:
                return json.dumps({'Account': account})
            if 'describe-cluster' in args:
                return json.dumps({'cluster': {'status': 'ACTIVE', 'endpoint': 'https://example.eks.amazonaws.com',
                    'certificateAuthority': {'data': 'test'}, 'resourcesVpcConfig': {
                        'endpointPrivateAccess': private, 'endpointPublicAccess': not updated,
                        'publicAccessCidrs': ['0.0.0.0/0']}}})
            if '--raw=/readyz' in args:
                config = json.loads(Path(args[args.index('--kubeconfig') + 1]).read_text())
                helper = config['users'][0]['user']['exec']
                self.assertEqual({entry['name']: entry['value'] for entry in helper['env']}, m.proxy_environment())
                self.assertNotIn('proxy-url', config['clusters'][0]['cluster'])
                return ready
            if 'can-i' in args:
                return 'yes'
            if 'update-cluster-config' in args:
                updated = True
                return '{"update":{"id":"test-update"}}'
            if 'describe-update' in args:
                return '{"update":{"status":"Successful"}}'
            raise AssertionError(args)
        with tempfile.TemporaryDirectory() as tmp, patch.object(m, 'run', side_effect=command), patch.object(m, 'require_private_dns'):
            args = SimpleNamespace(profile='test', region='us-east-1', account='123', cluster='test',
                                   apply=apply, access_paths_reviewed=reviewed, snapshot=str(Path(tmp)/'before.json'))
            try:
                m.migrate(args)
            except RuntimeError:
                self.assertFalse(any('update-cluster-config' in c for c in calls))
                raise
            if apply:
                saved = json.loads(Path(args.snapshot).read_text())
                self.assertTrue(saved['before']['endpointPublicAccess'])
                self.assertEqual(saved['before']['publicAccessCidrs'], ['0.0.0.0/0'])
        return calls

    def test_token_helper_restores_proxy_environment(self):
        with patch.dict(m.os.environ, {'HTTPS_PROXY': 'https://proxy.example:443',
                                      'https_proxy': 'https://lower.example:443'}):
            self.exercise(apply=True, reviewed=True)

    def test_default_never_mutates(self):
        self.assertFalse(any('update-cluster-config' in c for c in self.exercise()))

    def test_guards_refuse_mutation(self):
        for params in ({'account': 'wrong'}, {'private': False}, {'ready': 'failed'}, {'apply': True}):
            with self.subTest(params=params), self.assertRaises(RuntimeError):
                self.exercise(**params)

    def test_explicit_apply_preserves_snapshot_and_rechecks(self):
        calls = self.exercise(apply=True, reviewed=True)
        self.assertEqual(sum('update-cluster-config' in c for c in calls), 1)
        self.assertEqual(sum('--raw=/readyz' in c for c in calls), 2)


if __name__ == '__main__':
    unittest.main()
