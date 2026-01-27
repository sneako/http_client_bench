#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  curl \
  ca-certificates \
  gnupg2 \
  lsb-release

hostnamectl set-hostname finch-bench-server
if grep -q '^127.0.1.1' /etc/hosts; then
  sed -i 's/^127.0.1.1.*/127.0.1.1 finch-bench-server/' /etc/hosts
else
  echo "127.0.1.1 finch-bench-server" >> /etc/hosts
fi

curl -fsSL https://openresty.org/package/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/openresty.gpg

CODENAME=$(lsb_release -sc)
echo "deb [signed-by=/usr/share/keyrings/openresty.gpg] http://openresty.org/package/ubuntu ${CODENAME} main" > /etc/apt/sources.list.d/openresty.list

apt-get update
apt-get install -y --no-install-recommends openresty

cat >/etc/sysctl.d/99-finch-bench.conf <<'SYSCTL'
net.core.somaxconn=65535
net.ipv4.tcp_tw_reuse=1
net.ipv4.ip_local_port_range=10240 65535
fs.file-max=2097152
fs.nr_open=2097152
SYSCTL
sysctl --system

cat >/etc/security/limits.d/99-finch-bench.conf <<'LIMITS'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
ubuntu soft nofile 1048576
ubuntu hard nofile 1048576
LIMITS

mkdir -p /etc/systemd/system.conf.d
cat >/etc/systemd/system.conf.d/99-finch-bench.conf <<'SYSTEMD'
[Manager]
DefaultLimitNOFILE=1048576
SYSTEMD

systemctl daemon-reexec

systemctl disable --now openresty || true
