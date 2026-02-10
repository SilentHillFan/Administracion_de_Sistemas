#!/bin/bash

validar_segmento() {
    local ip=$1
    if [[ $ip =~ ^192\.168\.100\.([1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-4])$ ]]; then
        return 0
    else
        echo -e "\e[31mError: '$ip' debe estar en el segmento 192.168.100.x\e[0m"
        return 1
    fi
}

validar_dns() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && [[ $ip != "0.0.0.0" ]]; then
        return 0
    else
        echo -e "\e[31mError: '$ip' no es una IP valida para DNS\e[0m"
        return 1
    fi
}

instalar_dhcp() {
    echo "Iniciando proceso de instalacion desatendida..."
    wget -q https://mirror.stream.centos.org/9-stream/BaseOS/x86_64/os/Packages/dhcp-server-4.4.2-19.b1.el9.x86_64.rpm
    wget -q https://mirror.stream.centos.org/9-stream/BaseOS/x86_64/os/Packages/dhcp-common-4.4.2-19.b1.el9.noarch.rpm
    sudo yum localinstall -y dhcp-server-*.rpm dhcp-common-*.rpm &> /dev/null
    rm -f dhcp-server-*.rpm dhcp-common-*.rpm
    echo "Instalacion finalizada."
}

if ! command -v dhcpd &> /dev/null; then
    instalar_dhcp
fi

while true; do
    echo -e "\n=== MODULO DE MONITOREO Y CONFIGURACION (CENTOS 10) ==="
    echo "1. Configurar/Actualizar Ambito"
    echo "2. Consultar estado del servicio en tiempo real"
    echo "3. Listar concesiones (leases) activas"
    echo "4. Verificar o Reinstalar servicio"
    echo "5. Salir"
    read -p "Seleccione una opcion: " opcion

    case $opcion in
        1)
            read -p "Nombre de la red: " NAME
            while true; do read -p "IP Inicial (.100.x): " INICIO; validar_segmento "$INICIO" && break; done
            while true; do read -p "IP Final (.100.x): " FIN; validar_segmento "$FIN" && break; done
            while true; do read -p "Gateway (.100.x): " GW; validar_segmento "$GW" && break; done
            while true; do read -p "DNS: " DNS; validar_dns "$DNS" && break; done
            read -p "Lease Time (seg): " LEASE
            sudo bash -c "cat <<EOF > /etc/dhcp/dhcpd.conf
subnet 192.168.100.0 netmask 255.255.255.0 {
  range $INICIO $FIN;
  option routers $GW;
  option domain-name-servers $DNS;
  default-lease-time $LEASE;
  max-lease-time $LEASE;
}
EOF"
            sudo systemctl restart dhcpd &> /dev/null
            sudo systemctl enable dhcpd &> /dev/null
            ;;
        2)
            sudo systemctl status dhcpd --no-pager
            ;;
        3)
            if [ -f /var/lib/dhcpd/dhcpd.leases ]; then
                sudo grep -E "lease|hostname" /var/lib/dhcpd/dhcpd.leases | sed 's/lease /IP: /g; s/hostname /Equipo: /g; s/[{";]//g'
            else
                echo "No hay registros activos."
            fi
            ;;
        4)
            if command -v dhcpd &> /dev/null; then
                echo "El servicio esta instalado correctamente."
                read -p "Desea reinstalarlo? (s/n): " RI
                if [ "$RI" == "s" ]; then
                    sudo yum remove -y dhcp-server &> /dev/null
                    instalar_dhcp
                fi
            else
                instalar_dhcp
            fi
            ;;
        5) exit 0 ;;
    esac
done