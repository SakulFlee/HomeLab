# Seeder (first node)

> [!WARNING]
> The following has to be changed BEFORE running the command:  
> 1. advertise-address
> 2. node-ip
> 3. tls-san
> 4. node-name

   bash
curl -sfL https://get.k3s.io | sudo sh -s - server \
  --cluster-init \
  --node-ip=192.168.178.101,fd00::101 \
  --advertise-address=192.168.178.101 \
  --flannel-iface=eth0 \
  --flannel-ipv6-masq \
  --cluster-cidr=10.42.0.0/16,fd42::/56 \
  --service-cidr=10.43.0.0/16,fd43::/112 \
  --node-name k3s-aeris
   

# Any other node:

> [!WARNING]
> The following has to be changed BEFORE running the command: 
> 0. token
> 1. server
> 2. advertise-address
> 3. node-ip
> 4. node-name

   bash
curl -sfL https://get.k3s.io | sudo sh -s - server \
  --token <token at /var/lib/rancher/k3s/server/token on seeder> \
  --server https://192.168.178.101:6443 \
  --node-ip=192.168.178.102,fd00::102 \
  --flannel-iface=eth0 \
  --flannel-ipv6-masq \
  --cluster-cidr=10.42.0.0/16,fd42::/56 \
  --service-cidr=10.43.0.0/16,fd43::/112 \
  --node-name k3s-blyze

