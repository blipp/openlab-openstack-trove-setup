#!/bin/bash
ip link set down br-ex
ip addr add 10.0.21.1/24 dev br-ex
ip link set up br-ex
iptables -I FORWARD -i br-ex -j ACCEPT
iptables -I FORWARD -o br-ex -j ACCEPT
iptables -t nat -I POSTROUTING -s 10.0.21.0/24 ! -d 10.0.21.0/24 -j MASQUERADE
