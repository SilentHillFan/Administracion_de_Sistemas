#!/bin/bash

ip_to_int() {
    local IFS=.
    read -r i1 i2 i3 i4 <<< "$1"
    echo "$(( (i1 << 24) + (i2 << 16) + (i3 << 8) + i4 ))"
}

validar_ip() {
    local ip=$1
    local regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    
    if [[ ! $ip =~ $regex ]]; then return 1; fi

    IFS='.' read -r -a octs <<< "$ip"
    for o in "${octs[@]}"; do
        if [[ $o -lt 0 || $o -gt 255 ]]; then return 1; fi
    done

    if [[ "$ip" == "127.0.0.1" || "$ip" == "0.0.0.0" || "$ip" == "255.255.255.255" ]]; then
        return 1
    fi

    if [[ ${octs[2]} -eq 0 && ${octs[3]} -eq 0 ]]; then
        return 1
    fi

    return 0
}

opcion_verificar() {
    echo "__________________________________________"
    echo "Verificando instalacion..."
    if rpm -q dhcp &> /dev/null; then
        echo "El paquete DHCP esta instalado."
        systemctl is-active dhcpd
    else
        echo "El paquete DHCP NO esta instalado."
    fi
    read -p "Presiona Enter para continuar..."
}

opcion_instalar() {
    echo "__________________________________________"
    if ! rpm -q dhcp &> /dev/null; then
        echo "Instalando DHCP..."
        sudo yum install -y dhcp > /dev/null 2>&1
        echo "Instalacion completada."
    else
        echo "El servicio ya estaba instalado."
    fi
    read -p "Presiona Enter para continuar..."
}

opcion_configurar() {
    echo "++++++++++++++++++++++++++++++++++++++++++++++++++"
    echo "      CONFIGURACION DEL AMBITO      "
    echo "++++++++++++++++++++++++++++++++++++++++++++++++++"
    read -p "Nombre del Ambito (Scope): " SCOPE_NAME
    
    while true; do
        read -p "Rango Inicial IP: " IP_START
        if validar_ip "$IP_START"; then break; fi
    done

    while true; do
        read -p "Rango Final IP: " IP_END
        if validar_ip "$IP_END"; then
            INT_START=$(ip_to_int "$IP_START")
            INT_END=$(ip_to_int "$IP_END")
            
            if [[ $INT_END -le $INT_START ]]; then
                echo "   La IP Final debe ser MAYOR a la Inicial."
            else
                break 
            fi
        fi
    done

    read -p "Gateway (Opcional): " GW_IP
    read -p "DNS Server (Opcional): " DNS_IP
    read -p "Tiempo de concesion (Segundos): " LEASE_TIME

    # --- MAGIA SILENCIOSA ---
    SUBNET_PRE=$(echo $IP_START | cut -d'.' -f1-3)
    SUBNET_ID="$SUBNET_PRE.0"
    SERVER_NEW_IP="$SUBNET_PRE.1"
    
    # Forzamos usar la tarjeta de red interna
    INTERFAZ="enp0s8"

    echo "__________________________________________"
    echo "Red detectada: $SUBNET_ID"
    
    # Asignacion de IP Virtual (Sin mensajes)
    if ! ip addr show $INTERFAZ | grep -q "$SUBNET_PRE"; then
        sudo ip addr add $SERVER_NEW_IP/24 dev $INTERFAZ > /dev/null 2>&1
    fi

    CONF="/etc/dhcp/dhcpd.conf"
    sudo bash -c "cat > $CONF" <<EOF
subnet $SUBNET_ID netmask 255.255.255.0 {
    range $IP_START $IP_END;
    default-lease-time $LEASE_TIME;
    max-lease-time 7200;
EOF

    if [[ -n "$GW_IP" ]]; then
        sudo bash -c "echo '    option routers $GW_IP;' >> $CONF"
    fi
    if [[ -n "$DNS_IP" ]]; then
        sudo bash -c "echo '    option domain-name-servers $DNS_IP;' >> $CONF"
    fi
    
    sudo bash -c "echo '}' >> $CONF"

    if sudo dhcpd -t -cf $CONF > /dev/null 2>&1; then
        sudo systemctl restart dhcpd
        echo "Servicio configurado y reiniciado con exito."
    else
        echo "__________________________________________"
        echo "[ERROR] Error en la configuracion."
        sudo dhcpd -t -cf $CONF
    fi
    read -p "Presiona Enter para continuar..."
}

opcion_leases() {
    echo "__________________________________________"
    echo "CLIENTES CONECTADOS (Leases):"
    if [ -f /var/lib/dhcpd/dhcpd.leases ]; then
        grep "lease " /var/lib/dhcpd/dhcpd.leases | sort | uniq
    else
        echo "No hay registro de clientes."
    fi
    read -p "Presiona Enter para continuar..."
}

while true; do
    echo -e "\n++++++++++++++++++++++++++++++++++"
    echo "      SISTEMA DHCP"
    echo "++++++++++++++++++++++++++++++++++++"
    echo "1) Verificar instalacion "
    echo "2) Instalar DHCP"
    echo "3) Configurar Ambito"
    echo "4) Ver Leases (Clientes)"
    echo "5) Salir"
    echo "__________________________________________"
    read -p "Selecciona una opcion: " OPT
    
    case $OPT in
        1) opcion_verificar ;;
        2) opcion_instalar ;;
        3) opcion_configurar ;;
        4) opcion_leases ;;
        5) exit 0 ;;
        *) echo "Opcion invalida." ;;
    esac
done