# Aeris ("Seeder")

   bash
curl -sfL https://get.k3s.io | doas sh -s - server \
  --cluster-init \
  --node-ip=10.0.0.101,fd00:10::101 \
  --advertise-address=10.0.0.101 \
  --flannel-iface=eth1 \
  --bind-address=0.0.0.0 \
  --tls-san=192.168.178.101 \
  --cluster-cidr=10.42.0.0/16,fd42::/56 \
  --service-cidr=10.43.0.0/16,fd43::/112 \
  --kubelet-arg="node-ip=0.0.0.0" \
  --node-name k3s-aeris && tail -f /var/log/k3s.log
   

# Blyze

   bash
curl -sfL https://get.k3s.io | doas sh -s - server \
  --token <token from "seeder" at /var/lib/rancher/k3s/server/token> \
  --server https://10.0.0.101:6443 \
  --node-ip=10.0.0.102,fd00:10::102 \
  --advertise-address=10.0.0.102 \
  --flannel-iface=eth1 \
  --cluster-cidr=10.42.0.0/16,fd42::/56 \
  --service-cidr=10.43.0.0/16,fd43::/112 \
  --kubelet-arg="node-ip=0.0.0.0" \
  --node-name k3s-blyze && tail -f /var/log/k3s.log
   

# Cindry

   bash
curl -sfL https://get.k3s.io | doas sh -s - server \
  --token <token from "seeder" at /var/lib/rancher/k3s/server/token> \
  --server https://10.0.0.101:6443 \
  --node-ip=10.0.0.103,fd00:10::103 \
  --advertise-address=10.0.0.103 \
  --flannel-iface=eth1 \
  --cluster-cidr=10.42.0.0/16,fd42::/56 \
  --service-cidr=10.43.0.0/16,fd43::/112 \
  --kubelet-arg="node-ip=0.0.0.0" \
  --node-name k3s-blyze && tail -f /var/log/k3s.log
   
