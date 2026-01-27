#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  build-essential \
  git \
  curl \
  ca-certificates \
  unzip \
  rsync \
  jq \
  autoconf \
  m4 \
  libncurses5-dev \
  libncursesw5-dev \
  libssl-dev \
  libreadline-dev \
  libyaml-dev \
  libxml2-utils \
  xsltproc \
  fop \
  libxslt1-dev \
  libcurl4-openssl-dev

cat >/etc/profile.d/99-finch-bench.sh <<'ENVVARS'
if [[ -z "$${MIX_OS_DEPS_COMPILE_PARTITION_COUNT:-}" ]]; then
  sockets=$(lscpu | awk -F: '/Socket\\(s\\)/ {gsub(/ /,"",$2); print $2}' | head -n1)
  cores_per_socket=$(lscpu | awk -F: '/Core\\(s\\) per socket/ {gsub(/ /,"",$2); print $2}' | head -n1)
  if [[ -n "$sockets" && -n "$cores_per_socket" ]]; then
    cores=$((sockets * cores_per_socket))
  else
    cores=$(nproc --all)
  fi
  half=$((cores / 2))
  if [[ "$half" -le 0 ]]; then
    half=1
  fi
  export MIX_OS_DEPS_COMPILE_PARTITION_COUNT="$half"
fi
ENVVARS

hostnamectl set-hostname finch-bench-client
if grep -q '^127.0.1.1' /etc/hosts; then
  sed -i 's/^127.0.1.1.*/127.0.1.1 finch-bench-client/' /etc/hosts
else
  echo "127.0.1.1 finch-bench-client" >> /etc/hosts
fi

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

ERLANG_VERSION="${erlang_version}"
ELIXIR_VERSION="${elixir_version}"

su - ubuntu -c 'curl -fsSL https://mise.jdx.dev/install.sh | sh'
su - ubuntu -c "export PATH=\"$HOME/.local/bin:$PATH\"; export KERL_CONFIGURE_OPTIONS=\"--without-wx --disable-debug --without-odbc --without-javac\"; mise install erlang@$ERLANG_VERSION elixir@$ELIXIR_VERSION; mise global erlang@$ERLANG_VERSION elixir@$ELIXIR_VERSION"
