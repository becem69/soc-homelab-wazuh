#!/bin/sh
# SOC Firewall container entrypoint
# Enables IP forwarding and applies nftables ruleset

set -e

echo "[firewall] Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1

echo "[firewall] Loading nftables ruleset..."
nft -f /etc/nftables/nftables.conf

echo "[firewall] Ruleset loaded. Current tables:"
nft list ruleset | head -30

echo "[firewall] Counters:"
nft list counters

echo "[firewall] Firewall is active. Tailing logs..."
# Keep container alive and stream kernel firewall log messages
tail -f /var/log/messages 2>/dev/null || \
  dmesg -w 2>/dev/null || \
  while true; do
    echo "[firewall] alive at $(date)"
    sleep 60
  done
