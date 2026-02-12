#!/bin/bash

convertir_ip_a_entero() {
    local IFS=.
    read -r a b c d <<< "$1"
    echo "$(( (a << 24) + (b << 16) + (c << 8) + d ))"
}

es_ip_valida() {
    local direccion=$1
    local patron='^([0-9]{1,3}\.){3}[0-9]{1,3}$'

    if [[ ! $direccion =~ $patron ]]; then return 1; fi

    IFS='.' read -r -a partes <<< "$direccion"
    for segmento in "${partes[@]}"; do
        if [[ $segmento -lt 0 || $segmento -gt 255 ]]; then return 1; fi
    done

    if [[ "$direccion" == "127.0.0.1" || "$direccion" == "0.0.0.0" || "$direccion" == "255.255.255.255" ]]; then
        return 1
    fi

    if [[ ${partes[2]} -eq 0 && ${partes[3]} -eq 0 ]]; then
        return 1
    fi

    return 0
}

verificar_servicio() {
    echo "================================================="
    echo "Comprobando estado del servicio DHCP..."
    echo "================================================="

    if rpm -q dhcp &> /dev/null; then
        echo "DHCP se encuentra instalado en el sistema."
        systemctl is-active dhcpd
    else
        echo "DHCP no está instalado."
    fi

    read -p "Pulsa Enter para regresar al menú..."
}

instalar_servicio() {
    echo "================================================="

    if ! rpm -q dhcp &> /dev/null; then
        echo "Iniciando instalación de DHCP..."
        sudo yum install -y dhcp > /dev/null 2>&1
        echo "Instalación finalizada correctamente."
    else
        echo "DHCP ya estaba presente en el sistema."
    fi

    read -p "Pulsa Enter para regresar al menú..."
}

configurar_red_dhcp() {
    echo "================================================="
    echo "        ASISTENTE DE CONFIGURACIÓN DHCP"
    echo "================================================="

    read -p "Nombre del ámbito: " NOMBRE_AMBITO

    while true; do
        read -p "IP inicial del rango: " IP_INICIO
        if es_ip_valida "$IP_INICIO"; then break; fi
    done

    while true; do
        read -p "IP final del rango: " IP_FIN
        if es_ip_valida "$IP_FIN"; then
            INT_INICIO=$(convertir_ip_a_entero "$IP_INICIO")
            INT_FIN=$(convertir_ip_a_entero "$IP_FIN")

            if [[ $INT_FIN -le $INT_INICIO ]]; then
                echo "   [ERROR] La IP final debe ser mayor que la inicial."
            else
                break
            fi
        fi
    done

    read -p "Puerta de enlace (opcional): " IP_GATEWAY
    read -p "Servidor DNS (opcional): " IP_DNS
    read -p "Tiempo de concesión en segundos: " TIEMPO_LEASE

    SUBRED_BASE=$(echo $IP_INICIO | cut -d'.' -f1-3)
    ID_SUBRED="$SUBRED_BASE.0"
    IP_SERVIDOR="$SUBRED_BASE.1"

    INTERFAZ="enp0s8"

    echo "-------------------------------------------------"
    echo "Subred identificada: $ID_SUBRED"

    if ! ip addr show $INTERFAZ | grep -q "$SUBRED_BASE"; then
        sudo ip addr add $IP_SERVIDOR/24 dev $INTERFAZ > /dev/null 2>&1
    fi

    ARCHIVO_CONF="/etc/dhcp/dhcpd.conf"

    sudo bash -c "cat > $ARCHIVO_CONF" <<EOF
subnet $ID_SUBRED netmask 255.255.255.0 {
    range $IP_INICIO $IP_FIN;
    default-lease-time $TIEMPO_LEASE;
    max-lease-time 7200;
EOF

    if [[ -n "$IP_GATEWAY" ]]; then
        sudo bash -c "echo '    option routers $IP_GATEWAY;' >> $ARCHIVO_CONF"
    fi

    if [[ -n "$IP_DNS" ]]; then
        sudo bash -c "echo '    option domain-name-servers $IP_DNS;' >> $ARCHIVO_CONF"
    fi

    sudo bash -c "echo '}' >> $ARCHIVO_CONF"

    if dhcpd -t -cf $ARCHIVO_CONF > /dev/null 2>&1; then
        sudo systemctl restart dhcpd
        echo "Configuración aplicada y servicio reiniciado."
    else
        echo "================================================="
        echo "La configuración contiene errores."
        dhcpd -t -cf $ARCHIVO_CONF
    fi

    read -p "Pulsa Enter para regresar al menú..."
}

mostrar_clientes() {
    echo "================================================="
    echo "        LISTADO DE CLIENTES ACTIVOS"
    echo "================================================="

    if [ -f /var/lib/dhcpd/dhcpd.leases ]; then
        grep "lease " /var/lib/dhcpd/dhcpd.leases | sort | uniq
    else
        echo "No existen concesiones registradas."
    fi

    read -p "Pulsa Enter para regresar al menú..."
}

while true; do
    echo -e "\n#############################################"
    echo "         ADMINISTRADOR DE SERVIDOR DHCP"
    echo "#############################################"
    echo "1) Revisar estado del servicio"
    echo "2) Instalar DHCP"
    echo "3) Configurar nueva subred"
    echo "4) Mostrar clientes conectados"
    echo "5) Cerrar programa"
    echo "---------------------------------------------"

    read -p "Elige una opción: " OPCION

    case $OPCION in
        1) verificar_servicio ;;
        2) instalar_servicio ;;
        3) configurar_red_dhcp ;;
        4) mostrar_clientes ;;
        5) exit 0 ;;
        *) echo "Selección inválida." ;;
    esac
done
