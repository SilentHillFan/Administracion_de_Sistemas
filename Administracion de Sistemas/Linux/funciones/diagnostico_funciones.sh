#!/bin/bash
# diagnostico_funciones.sh

function mostrar_diagnostico() {
    echo "Nombre del equipo:"
    hostname

    echo "IP (Red Interna):"
    hostname -I | awk '{print $2}'

    echo "Espacio en disco:"
    df -h /
}
