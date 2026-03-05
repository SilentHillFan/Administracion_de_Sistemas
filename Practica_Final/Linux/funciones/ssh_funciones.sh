#!/bin/bash
# ssh_funciones.sh

function instalar_ssh() {
    yum install -y openssh-server
}

function habilitar_ssh() {
    systemctl enable sshd
    systemctl start sshd
}

function configurar_firewall_ssh() {
    firewall-cmd --permanent --add-service=ssh
    firewall-cmd --reload
}

function verificar_ssh() {
    systemctl status sshd --no-pager
    ss -tlnp | grep :22
}
