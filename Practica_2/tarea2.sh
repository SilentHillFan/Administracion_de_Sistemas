
wget -q https://mirror.stream.centos.org/9-stream/BaseOS/x86_64/os/Packages/dhcp-server-4.4.2-19.b1.el9.x86_64.rpm
wget -q https://mirror.stream.centos.org/9-stream/BaseOS/x86_64/os/Packages/dhcp-common-4.4.2-19.b1.el9.noarch.rpm

sudo yum localinstall -y dhcp-server-4.4.2-19.b1.el9.x86_64.rpm dhcp-common-4.4.2-19.b1.el9.noarch.rpm

read -p "Nombre de la red: " NAME

while true; do
    read -p "IP Inicio (192.168.100.50): " START
    ULTIMO=$(echo $START | cut -d. -f4)
    if [[ $START =~ ^192\.168\.100\. ]] && [ $ULTIMO -ge 50 ] && [ $ULTIMO -le 150 ]; then
        break
    else
        echo "Error: Use 192.168.100.x (rango 50-150)"
    fi
done

read -p "IP Fin: " END
read -p "IP del DNS: " DNS

sudo cat <<EOF > /etc/dhcp/dhcpd.conf
subnet 192.168.100.0 netmask 255.255.255.0 {
  range $START $END;
  option routers 192.168.100.1;
  option domain-name-servers $DNS;
}
EOF

sudo systemctl restart dhcpd
cat /var/lib/dhcp/dhcpd.leases