#!/bin/bash
# main.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/funciones/diagnostico_funciones.sh"
source "$SCRIPT_DIR/funciones/dhcp_funciones.sh"
source "$SCRIPT_DIR/funciones/dns_funciones.sh"
source "$SCRIPT_DIR/funciones/ssh_funciones.sh"
source "$SCRIPT_DIR/funciones/ftp_funciones.sh"

# Forzar permisos al iniciar
chmod +x "$SCRIPT_DIR/main.sh" 2>/dev/null
chmod +x "$SCRIPT_DIR/funciones/"*.sh 2>/dev/null

while true; do
    echo ""
    echo "++++++++++++++++++++++++++++++++++"
    echo "   MENU PRINCIPAL - CentOS 7"
    echo "++++++++++++++++++++++++++++++++++"
    echo "1) Diagnostico del sistema"
    echo "2) Gestion DHCP"
    echo "3) Gestion DNS"
    echo "4) Gestion SSH"
    echo "5) Gestion FTP"
    echo "6) Salir"
    echo "__________________________________________"
    read -p "Selecciona una opcion: " OPT

    case $OPT in
        1)
            mostrar_diagnostico
            ;;
        2)
            while true; do
                echo ""
                echo "++++++++++++++++++++++++++++++++++"
                echo "         SISTEMA DHCP"
                echo "++++++++++++++++++++++++++++++++++"
                echo "1) Verificar instalacion"
                echo "2) Instalar DHCP"
                echo "3) Configurar Ambito"
                echo "4) Ver Leases"
                echo "5) Volver"
                echo "__________________________________________"
                read -p "Selecciona una opcion: " OPT2
                case $OPT2 in
                    1) opcion_verificar ;;
                    2) opcion_instalar ;;
                    3) opcion_configurar ;;
                    4) opcion_leases ;;
                    5) break ;;
                    *) echo "Opcion invalida." ;;
                esac
            done
            ;;
        3)
            while true; do
                echo ""
                echo "++++++++++++++++++++++++++++++++++"
                echo "      SISTEMA DNS - CentOS 7"
                echo "++++++++++++++++++++++++++++++++++"
                echo "1) Verificar instalacion DNS"
                echo "2) Instalar DNS"
                echo "3) Agregar dominio"
                echo "4) Borrar dominio"
                echo "5) Ver dominios"
                echo "6) Volver"
                echo "__________________________________________"
                read -p "Selecciona una opcion: " OPT2
                case $OPT2 in
                    1) opcion_verificar ;;
                    2) opcion_instalar ;;
                    3) opcion_agregar ;;
                    4) opcion_borrar ;;
                    5) opcion_ver ;;
                    6) break ;;
                    *) echo "Opcion invalida." ;;
                esac
            done
            ;;
        4)
            while true; do
                echo ""
                echo "++++++++++++++++++++++++++++++++++"
                echo "      SISTEMA SSH - CentOS 7"
                echo "++++++++++++++++++++++++++++++++++"
                echo "1) Instalar SSH"
                echo "2) Habilitar SSH"
                echo "3) Configurar Firewall"
                echo "4) Verificar SSH"
                echo "5) Volver"
                echo "__________________________________________"
                read -p "Selecciona una opcion: " OPT2
                case $OPT2 in
                    1) instalar_ssh ;;
                    2) habilitar_ssh ;;
                    3) configurar_firewall_ssh ;;
                    4) verificar_ssh ;;
                    5) break ;;
                    *) echo "Opcion invalida." ;;
                esac
            done
            ;;
        5)
            while true; do
                echo ""
                echo "++++++++++++++++++++++++++++++++++"
                echo "      SISTEMA FTP - CentOS 7"
                echo "++++++++++++++++++++++++++++++++++"
                echo "1) Verificar/Instalar vsftpd"
                echo "2) Crear usuarios"
                echo "3) Ver usuarios"
                echo "4) Eliminar usuario"
                echo "5) Cambiar usuario de grupo"
                echo "6) Estado del servicio"
                echo "7) Reiniciar servicio"
                echo "8) Volver"
                echo "__________________________________________"
                read -p "Selecciona una opcion: " OPT2
                case $OPT2 in
                    1) opcion_instalar_ftp ;;
                    2) opcion_crear_usuarios ;;
                    3) opcion_ver_usuarios ;;
                    4) opcion_eliminar_usuario ;;
                    5) opcion_cambiar_grupo ;;
                    6) opcion_estado_ftp ;;
                    7) opcion_reiniciar_ftp ;;
                    8) break ;;
                    *) echo "Opcion invalida." ;;
                esac
            done
            ;;
        6) exit 0 ;;
        *) echo "Opcion invalida." ;;
    esac
done
