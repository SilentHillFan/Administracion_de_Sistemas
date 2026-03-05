#!/bin/bash

FTP_ROOT="/srv/ftp"
GRUPOS=("reprobados" "recursadores")

function crear_estructura_base() {
    sudo mkdir -p "$FTP_ROOT/general"
    sudo mkdir -p "$FTP_ROOT/reprobados"
    sudo mkdir -p "$FTP_ROOT/recursadores"

    for grupo in "${GRUPOS[@]}"; do
        if ! getent group "$grupo" &>/dev/null; then
            sudo groupadd "$grupo"
            echo "Grupo '$grupo' creado."
        fi
    done

  
    sudo chown root:ftp "$FTP_ROOT/general"
    sudo chmod 775 "$FTP_ROOT/general"

    sudo chown root:reprobados "$FTP_ROOT/reprobados"
    sudo chmod 770 "$FTP_ROOT/reprobados"

    sudo chown root:recursadores "$FTP_ROOT/recursadores"
    sudo chmod 770 "$FTP_ROOT/recursadores"

    sudo mkdir -p "$FTP_ROOT/usuarios"
    sudo chown root:root "$FTP_ROOT/usuarios"
    sudo chmod 711 "$FTP_ROOT/usuarios"  

    sudo chown root:root "$FTP_ROOT"
    sudo chmod 755 "$FTP_ROOT"

    if ! grep -q "/sbin/nologin" /etc/shells; then
        echo "/sbin/nologin" | sudo tee -a /etc/shells > /dev/null
    fi
}

function opcion_instalar_ftp() {
    echo "__________________________________________"
    echo "Verificando instalacion de vsftpd..."

    if rpm -q vsftpd &>/dev/null; then
        echo "vsftpd ya esta instalado."
        read -p "Deseas reinstalarlo? (s/n): " resp
        if [[ "$resp" != "s" && "$resp" != "S" ]]; then
            read -p "Presiona Enter para continuar..."
            return
        fi
        sudo yum remove -y vsftpd -q &>/dev/null
    fi

    echo "Instalando vsftpd..."
    sudo yum install -y vsftpd -q &>/dev/null

    echo "Configurando vsftpd..."
    crear_estructura_base

    sudo cp /etc/vsftpd/vsftpd.conf /etc/vsftpd/vsftpd.conf.bak 2>/dev/null

    sudo tee /etc/vsftpd/vsftpd.conf > /dev/null <<EOF

anonymous_enable=YES
anon_root=$FTP_ROOT
no_anon_password=YES
anon_upload_enable=NO
anon_mkdir_write_enable=NO
allow_writeable_chroot=YES


local_enable=YES
write_enable=YES
local_umask=022
chroot_local_user=YES
allow_writeable_chroot=YES


dirmessage_enable=YES
xferlog_enable=YES
connect_from_port_20=YES
xferlog_std_format=YES
listen=YES
listen_ipv6=NO
pam_service_name=vsftpd


userlist_enable=YES
userlist_deny=NO
userlist_file=/etc/vsftpd/ftp_usuarios.list


user_sub_token=\$USER
local_root=$FTP_ROOT/usuarios/\$USER
EOF


    echo "anonymous" | sudo tee /etc/vsftpd/ftp_usuarios.list > /dev/null
    sudo chmod 644 /etc/vsftpd/ftp_usuarios.list

    sudo firewall-cmd --permanent --add-service=ftp &>/dev/null
    sudo firewall-cmd --reload &>/dev/null


    sudo setsebool -P ftpd_full_access 1 &>/dev/null
    sudo setsebool -P ftpd_anon_write 1 &>/dev/null

    sudo systemctl enable vsftpd &>/dev/null
    sudo systemctl restart vsftpd

    if systemctl is-active vsftpd &>/dev/null; then
        echo "vsftpd instalado y configurado correctamente."
    else
        echo "[ERROR] vsftpd no pudo iniciarse. Revisa: journalctl -xe"
    fi

    read -p "Presiona Enter para continuar..."
}

function opcion_estado_ftp() {
    echo "__________________________________________"
    echo "ESTADO DEL SERVICIO vsftpd:"
    echo ""
    sudo systemctl status vsftpd
    echo ""
    read -p "Presiona Enter para continuar..."
}

function opcion_reiniciar_ftp() {
    echo "__________________________________________"
    echo "Reiniciando vsftpd..."
    sudo systemctl restart vsftpd
    if systemctl is-active vsftpd &>/dev/null; then
        echo "vsftpd reiniciado correctamente."
    else
        echo "[ERROR] vsftpd no pudo reiniciarse."
    fi
    read -p "Presiona Enter para continuar..."
}

function verificar_ftp_instalado() {
    if ! rpm -q vsftpd &>/dev/null || ! systemctl is-active vsftpd &>/dev/null; then
        echo "vsftpd no esta instalado o no esta corriendo."
        echo "Ve al menu e instala vsftpd primero."
        read -p "Presiona Enter para continuar..."
        return 1
    fi
    return 0
}

function opcion_crear_usuarios() {
    verificar_ftp_instalado || return
    echo "++++++++++++++++++++++++++++++++++++++++++++++++++"
    echo "            CREAR USUARIOS FTP"
    echo "++++++++++++++++++++++++++++++++++++++++++++++++++"

    read -p "Cuantos usuarios deseas crear (max 10): " N

    if ! [[ "$N" =~ ^[0-9]+$ ]] || [[ "$N" -lt 1 ]]; then
        echo "Numero invalido."
        read -p "Presiona Enter para continuar..."
        return
    fi

    if [[ "$N" -gt 10 ]]; then
        echo "No puedes crear mas de 10 usuarios a la vez."
        read -p "Presiona Enter para continuar..."
        return
    fi

    for (( i=1; i<=N; i++ )); do
        echo ""
        echo "--- Usuario $i de $N ---"

        read -p "Nombre de usuario: " USERNAME
        if [[ -z "$USERNAME" ]]; then
            echo "Nombre vacio, saltando..."
            continue
        fi

        if id "$USERNAME" &>/dev/null; then
            echo "El usuario '$USERNAME' ya existe, saltando..."
            continue
        fi

        read -s -p "Contrasena: " PASSWORD
        echo ""
        if [[ -z "$PASSWORD" ]]; then
            echo "Contrasena vacia, saltando..."
            continue
        fi

        echo "Grupo:"
        echo "  1) reprobados"
        echo "  2) recursadores"
        read -p "Selecciona (1 o 2): " GRUPO_SEL

        if [[ "$GRUPO_SEL" == "1" ]]; then
            GRUPO="reprobados"
        elif [[ "$GRUPO_SEL" == "2" ]]; then
            GRUPO="recursadores"
        else
            echo "Opcion invalida, saltando..."
            continue
        fi

        USER_HOME="$FTP_ROOT/usuarios/$USERNAME"

        sudo useradd -m -d "$USER_HOME" -s /sbin/nologin -g "$GRUPO" -G ftp "$USERNAME"
        echo "$USERNAME:$PASSWORD" | sudo chpasswd

       
        sudo mkdir -p "$USER_HOME/general"
        sudo mkdir -p "$USER_HOME/$GRUPO"
        sudo mkdir -p "$USER_HOME/$USERNAME"

      
        sudo mount --bind "$FTP_ROOT/general" "$USER_HOME/general"
        sudo mount --bind "$FTP_ROOT/$GRUPO" "$USER_HOME/$GRUPO"

        if ! grep -q "$USER_HOME/general" /etc/fstab; then
            echo "$FTP_ROOT/general  $USER_HOME/general  none  bind  0 0" | sudo tee -a /etc/fstab > /dev/null
        fi
        if ! grep -q "$USER_HOME/$GRUPO" /etc/fstab; then
            echo "$FTP_ROOT/$GRUPO  $USER_HOME/$GRUPO  none  bind  0 0" | sudo tee -a /etc/fstab > /dev/null
        fi

         
        sudo chown root:root "$USER_HOME"
        sudo chmod 755 "$USER_HOME"

        
        sudo chown "$USERNAME":"$GRUPO" "$USER_HOME/$USERNAME"
        sudo chmod 700 "$USER_HOME/$USERNAME"

      

        if ! grep -q "^$USERNAME$" /etc/vsftpd/ftp_usuarios.list; then
            echo "$USERNAME" | sudo tee -a /etc/vsftpd/ftp_usuarios.list > /dev/null
        fi

        echo "Usuario '$USERNAME' creado en grupo '$GRUPO'."
        echo "  Directorios accesibles:"
        echo "    /$USERNAME      -> escritura personal"
        echo "    /general        -> escritura publica"
        echo "    /$GRUPO         -> escritura de grupo"
    done

    sudo systemctl restart vsftpd &>/dev/null
    read -p "Presiona Enter para continuar..."
}

function opcion_ver_usuarios() {
    verificar_ftp_instalado || return
    echo "__________________________________________"
    echo "USUARIOS FTP REGISTRADOS:"
    echo ""

    i=1
    encontrado=0
    while IFS= read -r usuario; do
        [[ -z "$usuario" ]] && continue
        GRUPO_USER=$(id -gn "$usuario" 2>/dev/null)
        if [[ "$GRUPO_USER" == "reprobados" ]] || [[ "$GRUPO_USER" == "recursadores" ]]; then
            echo "  $i) $usuario  [grupo: $GRUPO_USER]"
            ((i++))
            encontrado=1
        fi
    done < /etc/vsftpd/ftp_usuarios.list

    if [[ "$encontrado" -eq 0 ]]; then
        echo "No hay usuarios registrados."
    fi

    echo ""
    read -p "Presiona Enter para continuar..."
}

function opcion_eliminar_usuario() {
    verificar_ftp_instalado || return
    echo "__________________________________________"

    if [[ ! -f /etc/vsftpd/ftp_usuarios.list ]] || [[ ! -s /etc/vsftpd/ftp_usuarios.list ]]; then
        echo "No hay usuarios registrados."
        read -p "Presiona Enter para continuar..."
        return
    fi

   
    mapfile -t USUARIOS < <(grep -v '^$' /etc/vsftpd/ftp_usuarios.list | grep -v '^anonymous$')

    if [[ ${#USUARIOS[@]} -eq 0 ]]; then
        echo "No hay usuarios registrados."
        read -p "Presiona Enter para continuar..."
        return
    fi

    echo "Usuarios registrados:"
    echo ""
    for i in "${!USUARIOS[@]}"; do
        GRUPO_USER=$(id -gn "${USUARIOS[$i]}" 2>/dev/null || echo "desconocido")
        echo "  $((i+1))) ${USUARIOS[$i]}  [grupo: $GRUPO_USER]"
    done
    echo "  0) Cancelar"
    echo ""

    while true; do
        read -p "Selecciona el numero del usuario a eliminar: " SEL
        if [[ "$SEL" == "0" ]]; then
            echo "Operacion cancelada."
            read -p "Presiona Enter para continuar..."
            return
        fi
        if [[ "$SEL" =~ ^[0-9]+$ ]] && [[ "$SEL" -ge 1 ]] && [[ "$SEL" -le ${#USUARIOS[@]} ]]; then
            break
        else
            echo "Opcion invalida."
        fi
    done

    USERNAME="${USUARIOS[$((SEL-1))]}"
    USER_HOME="$FTP_ROOT/usuarios/$USERNAME"   

    read -p "Confirmas eliminar '$USERNAME'? (s/n): " CONFIRM
    if [[ "$CONFIRM" != "s" && "$CONFIRM" != "S" ]]; then
        echo "Operacion cancelada."
        read -p "Presiona Enter para continuar..."
        return
    fi

    GRUPO_USER=$(id -gn "$USERNAME" 2>/dev/null)

    
    sudo umount -l "$USER_HOME/general" 2>/dev/null
    sudo umount -l "$USER_HOME/$GRUPO_USER" 2>/dev/null
    sleep 1

    sudo sed -i "\|$USER_HOME|d" /etc/fstab   
    sudo rm -rf "$USER_HOME"
    sudo userdel "$USERNAME" 2>/dev/null
    sudo sed -i "/^$USERNAME$/d" /etc/vsftpd/ftp_usuarios.list

    echo "Usuario '$USERNAME' eliminado correctamente."
    sudo systemctl restart vsftpd &>/dev/null
    read -p "Presiona Enter para continuar..."
}

function opcion_cambiar_grupo() {
    verificar_ftp_instalado || return
    echo "__________________________________________"

    if [[ ! -f /etc/vsftpd/ftp_usuarios.list ]] || [[ ! -s /etc/vsftpd/ftp_usuarios.list ]]; then
        echo "No hay usuarios registrados."
        read -p "Presiona Enter para continuar..."
        return
    fi

    mapfile -t USUARIOS < <(grep -v '^$' /etc/vsftpd/ftp_usuarios.list | grep -v '^anonymous$')

    if [[ ${#USUARIOS[@]} -eq 0 ]]; then
        echo "No hay usuarios registrados."
        read -p "Presiona Enter para continuar..."
        return
    fi

    echo "Usuarios registrados:"
    echo ""
    for i in "${!USUARIOS[@]}"; do
        GRUPO_USER=$(id -gn "${USUARIOS[$i]}" 2>/dev/null || echo "desconocido")
        echo "  $((i+1))) ${USUARIOS[$i]}  [grupo actual: $GRUPO_USER]"
    done
    echo "  0) Cancelar"
    echo ""

    while true; do
        read -p "Selecciona el numero del usuario a cambiar de grupo: " SEL
        if [[ "$SEL" == "0" ]]; then
            echo "Operacion cancelada."
            read -p "Presiona Enter para continuar..."
            return
        fi
        if [[ "$SEL" =~ ^[0-9]+$ ]] && [[ "$SEL" -ge 1 ]] && [[ "$SEL" -le ${#USUARIOS[@]} ]]; then
            break
        else
            echo "Opcion invalida."
        fi
    done

    USERNAME="${USUARIOS[$((SEL-1))]}"
    GRUPO_ACTUAL=$(id -gn "$USERNAME" 2>/dev/null)
    USER_HOME="$FTP_ROOT/usuarios/$USERNAME"

    echo ""
    echo "Nuevo grupo para '$USERNAME':"
    echo "  1) reprobados"
    echo "  2) recursadores"
    read -p "Selecciona (1 o 2): " GRUPO_SEL

    if [[ "$GRUPO_SEL" == "1" ]]; then
        NUEVO_GRUPO="reprobados"
    elif [[ "$GRUPO_SEL" == "2" ]]; then
        NUEVO_GRUPO="recursadores"
    else
        echo "Opcion invalida."
        read -p "Presiona Enter para continuar..."
        return
    fi

    if [[ "$NUEVO_GRUPO" == "$GRUPO_ACTUAL" ]]; then
        echo "El usuario ya pertenece a ese grupo."
        read -p "Presiona Enter para continuar..."
        return
    fi

   
    sudo umount -l "$USER_HOME/$GRUPO_ACTUAL" 2>/dev/null
    sudo rm -rf "$USER_HOME/$GRUPO_ACTUAL"
    sudo sed -i "\|$USER_HOME/$GRUPO_ACTUAL|d" /etc/fstab  
   
    sudo usermod -g "$NUEVO_GRUPO" "$USERNAME"

    
    sudo mkdir -p "$USER_HOME/$NUEVO_GRUPO"
    sudo mount --bind "$FTP_ROOT/$NUEVO_GRUPO" "$USER_HOME/$NUEVO_GRUPO"

    if ! grep -q "$USER_HOME/$NUEVO_GRUPO" /etc/fstab; then
        echo "$FTP_ROOT/$NUEVO_GRUPO  $USER_HOME/$NUEVO_GRUPO  none  bind  0 0" | sudo tee -a /etc/fstab > /dev/null
    fi

    echo "Usuario '$USERNAME' cambiado de '$GRUPO_ACTUAL' a '$NUEVO_GRUPO'."
    sudo systemctl restart vsftpd &>/dev/null
    read -p "Presiona Enter para continuar..."
}
