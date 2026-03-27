#!/bin/bash

DOMINIO="reprobados.com"
DOMINIO_UPPER="REPROBADOS.COM"
DC_IP="192.168.56.102"
ADMIN_USER="Administrator"

if [ "$EUID" -ne 0 ]; then
    echo "[!] Ejecuta como root: sudo bash unir_dominio.sh"
    exit 1
fi

echo "========================================="
echo " UNION AL DOMINIO: $DOMINIO"
echo "========================================="

echo "[*] Configurando DNS..."
cat > /etc/resolv.conf << RESOLVEOF
nameserver $DC_IP
search $DOMINIO
RESOLVEOF
chattr +i /etc/resolv.conf 2>/dev/null
echo "[OK] DNS configurado."

echo "[*] Sincronizando tiempo con el servidor..."
if command -v timedatectl &>/dev/null; then
    timedatectl set-ntp true
fi
if command -v chronyc &>/dev/null; then
    chronyc makestep
elif command -v ntpdate &>/dev/null; then
    ntpdate -u $DC_IP 2>/dev/null
fi

echo "[*] Instalando paquetes: realmd, sssd, adcli, krb5..."
DEBIAN_FRONTEND=noninteractive apt install -yq realmd sssd sssd-tools adcli krb5-user samba-common-bin packagekit oddjob oddjob-mkhomedir
echo "[OK] Paquetes instalados."

echo "[*] Descubriendo dominio $DOMINIO..."
realm discover $DOMINIO
if [ $? -ne 0 ]; then
    echo "[!] No se pudo descubrir el dominio. Verifica conectividad con $DC_IP"
    exit 1
fi

echo "[*] Uniendose al dominio $DOMINIO..."
echo "--> ATENCION: Ingresa la contrasena del $ADMIN_USER (Contrasena123)"
realm join --user=$ADMIN_USER $DOMINIO
if [ $? -ne 0 ]; then
    echo "[!] Error al unirse al dominio."
    exit 1
fi
echo "[OK] Unido al dominio $DOMINIO."

echo "[*] Configurando sssd.conf..."
cat > /etc/sssd/sssd.conf << SSSDEOF
[sssd]
domains = $DOMINIO
config_file_version = 2
services = nss, pam

[domain/$DOMINIO]
ad_domain = $DOMINIO
krb5_realm = $DOMINIO_UPPER
realmd_tags = manages-system joined-with-adcli
cache_credentials = True
id_provider = ad
fallback_homedir = /home/%u@%d
default_shell = /bin/bash
ldap_id_mapping = True
use_fully_qualified_names = True
deny_access_order = deny, allow
ad_gpo_access_control = permissive
SSSDEOF

chmod 600 /etc/sssd/sssd.conf
systemctl enable --now sssd
systemctl restart sssd
echo "[OK] sssd configurado."

echo "[*] Habilitando pam_mkhomedir..."
if command -v pam-auth-update &>/dev/null; then
    pam-auth-update --enable mkhomedir
else
    echo "session required pam_mkhomedir.so" >> /etc/pam.d/common-session
fi
echo "[OK] Home directory automatico habilitado."

echo "[*] Configurando sudo para usuarios del dominio..."
cat > /etc/sudoers.d/ad-admins << SUDOEOF
%domain\ users@$DOMINIO ALL=(ALL) ALL
SUDOEOF
chmod 440 /etc/sudoers.d/ad-admins
echo "[OK] Sudo configurado."

echo ""
echo "========================================="
echo " VERIFICACION FINAL"
echo "========================================="
realm list
echo ""
echo "[*] Probando resolucion de usuario AD..."
id "dromero@$DOMINIO" 2>/dev/null && echo "[OK] Usuario dromero encontrado en AD" || echo "[!] Usuario no encontrado aun - normal, espera unos segundos y reintenta"

echo ""
echo "[OK] Union al dominio completada."
echo "     Puedes iniciar sesion con: su - dromero@$DOMINIO"
echo "     Contrasena: Contrasena123"
