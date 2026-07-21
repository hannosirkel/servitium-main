#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
rendered="$(mktemp)"
trap 'rm -f -- "$rendered"' EXIT

kubectl kustomize "$repo_root" >"$rendered"

ruby -ryaml - "$rendered" <<'RUBY'
documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact

def resource(documents, kind, name)
  matches = documents.select do |document|
    document['kind'] == kind && document.dig('metadata', 'name') == name
  end
  raise "expected one #{kind}/#{name}" unless matches.length == 1
  matches.first
end

raise 'Ingress is forbidden' if documents.any? { |item| item['kind'] == 'Ingress' }

namespace = resource(documents, 'Namespace', 'servitium')
labels = namespace.dig('metadata', 'labels')
raise 'restricted pod security is required' unless
  labels['pod-security.kubernetes.io/enforce'] == 'restricted' &&
  labels['pod-security.kubernetes.io/enforce-version'] == 'latest'

deployment = resource(documents, 'Deployment', 'servitium')
spec = deployment.fetch('spec')
raise 'deployment must use Recreate' unless spec['strategy'] == { 'type' => 'Recreate' }
pod = spec.dig('template', 'spec')
raise 'service account token must be disabled' unless
  pod['automountServiceAccountToken'] == false
raise 'host namespaces are forbidden' if
  pod['hostNetwork'] || pod['hostPID'] || pod['hostIPC']
raise 'pod identity mismatch' unless pod['securityContext'] == {
  'fsGroup' => 10_001,
  'fsGroupChangePolicy' => 'OnRootMismatch',
  'runAsNonRoot' => true,
  'runAsUser' => 10_001,
  'runAsGroup' => 10_001,
  'seccompProfile' => { 'type' => 'RuntimeDefault' },
}

container = pod.fetch('containers').fetch(0)
raise 'image must use an immutable digest' unless
  container['image'].match?(/\Aghcr\.io\/hannosirkel\/servitium@sha256:[0-9a-f]{64}\z/)
raise 'container port exposure mismatch' unless container['ports'] == [{
  'name' => 'http', 'containerPort' => 8099, 'protocol' => 'TCP'
}]
raise 'container hardening mismatch' unless container['securityContext'] == {
  'allowPrivilegeEscalation' => false,
  'capabilities' => { 'drop' => ['ALL'] },
  'readOnlyRootFilesystem' => true,
  'runAsNonRoot' => true,
  'runAsUser' => 10_001,
  'runAsGroup' => 10_001,
}
raise 'resource contract mismatch' unless container['resources'] == {
  'requests' => { 'cpu' => '100m', 'memory' => '64Mi' },
  'limits' => { 'cpu' => '250m', 'memory' => '128Mi' },
}

environment = container.fetch('env').to_h { |entry| [entry['name'], entry['value']] }
raise 'database environment mismatch' unless environment == {
  'MYSQL_HOST' => 'mysql.mysql.svc.cluster.local',
  'MYSQL_PORT' => '3306',
  'MYSQL_DATABASE' => 'servitium',
  'MYSQL_USER' => 'servitium',
}
mount = container.fetch('volumeMounts').fetch(0)
raise 'secret mount mismatch' unless mount == {
  'name' => 'servitium-secrets',
  'mountPath' => '/run/secrets/servitium',
  'readOnly' => true,
}
secret = pod.fetch('volumes').fetch(0).fetch('secret')
raise 'secret projection mismatch' unless
  secret['secretName'] == 'servitium-secrets' &&
  secret['defaultMode'] == 256 &&
  secret['items'] == [
    { 'key' => 'bot-token', 'path' => 'discord-bot-token' },
    { 'key' => 'password', 'path' => 'mysql-password' },
  ]

service = resource(documents, 'Service', 'servitium')
raise 'service must remain ClusterIP' unless
  service.dig('spec', 'type') == 'ClusterIP'
raise 'WireGuard-only service address mismatch' unless
  service.dig('spec', 'externalIPs') == ['192.168.21.2']
raise 'service port mismatch' unless service.dig('spec', 'ports') == [{
  'name' => 'http', 'port' => 8099, 'protocol' => 'TCP', 'targetPort' => 'http'
}]
forbidden_service_keys = %w[externalName loadBalancerIP loadBalancerClass]
raise 'explicit service addresses are forbidden' if
  forbidden_service_keys.any? { |key| service.fetch('spec').key?(key) }

default_deny = resource(documents, 'NetworkPolicy', 'default-deny')
raise 'default deny mismatch' unless
  default_deny.dig('spec', 'policyTypes').sort == %w[Egress Ingress]

ingress = resource(documents, 'NetworkPolicy', 'allow-wireguard-http')
raise 'WireGuard ingress mismatch' unless ingress.dig('spec', 'ingress') == [{
  'from' => [
    { 'ipBlock' => { 'cidr' => '192.168.21.0/24' } },
    { 'ipBlock' => { 'cidr' => '192.168.1.0/24' } },
  ],
  'ports' => [{ 'port' => 8099, 'protocol' => 'TCP' }],
}]

dns = resource(documents, 'NetworkPolicy', 'allow-dns-egress')
dns_ports = dns.dig('spec', 'egress', 0, 'ports')
raise 'DNS egress mismatch' unless dns_ports == [
  { 'port' => 53, 'protocol' => 'UDP' },
  { 'port' => 53, 'protocol' => 'TCP' },
]
mysql = resource(documents, 'NetworkPolicy', 'allow-mysql-egress')
raise 'MySQL egress mismatch' unless mysql.dig('spec', 'egress') == [{
  'to' => [{ 'namespaceSelector' => { 'matchLabels' => {
    'kubernetes.io/metadata.name' => 'mysql'
  } } }],
  'ports' => [{ 'port' => 3306, 'protocol' => 'TCP' }],
}]

rendered = File.read(ARGV.fetch(0))
raise 'IPv6 exposure is forbidden' if rendered.include?('::')
raise 'public ingress CIDRs are forbidden' if rendered.include?('0.0.0.0/0')
puts 'manifest contract tests passed'
RUBY
