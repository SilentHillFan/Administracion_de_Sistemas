#!/bin/bash

APACHE_CONF="/etc/httpd/conf/httpd.conf"
APACHE_SECURITY="/etc/httpd/conf.d/security.conf"
APACHE_WEBROOT="/var/www/html"
NGINX_CONF="/etc/nginx/nginx.conf"
NGINX_WEBROOT="/var/www/nginx"
TOMCAT_HOME="/opt/tomcat"
TOMCAT_USER="tomcat"
TOMCAT_GROUP="tomcat"
PUERTOS_RESERVADOS=(21 22 23 25 53 67 68 110 143 161 443 445 3306 5432 8443)
_PUERTO=""

_verificar_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "[ERROR] Se requieren privilegios de root."
        return 1
    fi
    return 0
}

_validar_puerto() {
    local puerto="$1"
    if [ -z "$puerto" ]; then echo "[ERROR] Puerto vacio." >&2; return 1; fi
    if [[ ! "$puerto" =~ ^[0-9]+$ ]]; then echo "[ERROR] Solo numeros." >&2; return 1; fi
    if [ "$puerto" -lt 1 ] || [ "$puerto" -gt 65535 ]; then echo "[ERROR] Rango 1-65535." >&2; return 1; fi
    for p in "${PUERTOS_RESERVADOS[@]}"; do
        if [ "$puerto" -eq "$p" ]; then echo "[ERROR] Puerto $puerto reservado." >&2; return 1; fi
    done
    if ss -tlnp 2>/dev/null | awk '{print $4}' | grep -qE ":${puerto}$"; then
        echo "[ERROR] Puerto $puerto ya en uso." >&2; return 1
    fi
    return 0
}

_leer_puerto() {
    _PUERTO=""
    local input
    while true; do
        read -p "  Puerto de escucha: " input
        input="${input//[[:space:]]/}"
        if _validar_puerto "$input"; then _PUERTO="$input"; return 0; fi
    done
}

_configurar_firewall() {
    local nuevo_puerto="$1"
    local puerto_default="${2:-80}"
    firewall-cmd --permanent --add-port="${nuevo_puerto}/tcp" &>/dev/null
    if [ "$nuevo_puerto" -ne "$puerto_default" ]; then
        if ! ss -tlnp 2>/dev/null | awk '{print $4}' | grep -qE ":${puerto_default}$"; then
            firewall-cmd --permanent --remove-service=http  &>/dev/null
            firewall-cmd --permanent --remove-service=https &>/dev/null
            firewall-cmd --permanent --remove-port="${puerto_default}/tcp" &>/dev/null
        fi
    fi
    firewall-cmd --reload &>/dev/null
}

_crear_index_html() {
    local servicio="$1" version="$2" puerto="$3" ruta="$4"
    mkdir -p "$ruta"
    cat > "$ruta/index.html" <<EOF
<!DOCTYPE html>
<html lang="es">
<head><meta charset="UTF-8"><title>${servicio}</title></head>
<body>
    <h1>${servicio}</h1>
    <p>Servidor: ${servicio}</p>
    <p>Version: ${version}</p>
    <p>Puerto: ${puerto}</p>
</body>
</html>
EOF
}

_obtener_versiones_apache() {
    local versiones
    versiones=$(yum --showduplicates list httpd 2>/dev/null | awk '/^httpd\./{print $2}' | sort -Vu)
    [ -z "$versiones" ] && versiones=$(yum info httpd 2>/dev/null | awk '/^Version/{print $3}')
    echo "$versiones"
}

instalar_apache() {
    _verificar_root || return 1
    local versiones_raw i=1
    versiones_raw=$(_obtener_versiones_apache)
    if [ -z "$versiones_raw" ]; then echo "[ERROR] No hay versiones de Apache disponibles."; return 1; fi

    echo ""
    echo "  Versiones disponibles de Apache:"
    declare -A _mapa_apache
    while IFS= read -r ver; do
        printf "  %2d) %s\n" "$i" "$ver"
        _mapa_apache[$i]="$ver"; ((i++))
    done <<< "$versiones_raw"
    echo ""
    local sel input
    while true; do
        read -p "  Opcion [1-$((i-1))]: " input
        input="${input//[[:space:]]/}"
        [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le $((i-1)) ] && { sel="$input"; break; }
        echo "[ERROR] Opcion invalida." >&2
    done
    local version_elegida="${_mapa_apache[$sel]}"

    _leer_puerto
    local puerto="$_PUERTO"

    yum install -y "httpd-${version_elegida}" &>/dev/null || yum install -y httpd &>/dev/null
    if ! rpm -q httpd &>/dev/null; then echo "[ERROR] Instalacion de Apache fallida."; return 1; fi

    local ver_instalada
    ver_instalada=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' httpd)
    id apache &>/dev/null || useradd -r -s /sbin/nologin -d "$APACHE_WEBROOT" apache
    chown -R apache:apache "$APACHE_WEBROOT"
    chmod -R 750 "$APACHE_WEBROOT"
    sed -i "s/^Listen .*/Listen $puerto/" "$APACHE_CONF"
    _crear_index_html "Apache" "$ver_instalada" "$puerto" "$APACHE_WEBROOT"

    httpd -M 2>/dev/null | grep -q headers_module || \
        echo "LoadModule headers_module modules/mod_headers.so" >> /etc/httpd/conf.modules.d/00-base.conf 2>/dev/null

    cat > "$APACHE_SECURITY" <<'SECEOF'
ServerTokens Prod
ServerSignature Off
TraceEnable Off
<IfModule mod_headers.c>
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-XSS-Protection "1; mode=block"
    Header unset Server
    Header always unset X-Powered-By
</IfModule>
<Directory "/var/www/html">
    Options -Indexes
    AllowOverride None
    Require all granted
    <LimitExcept GET POST HEAD>
        Require all denied
    </LimitExcept>
</Directory>
SECEOF

    if [ "$puerto" -ne 80 ] && [ "$puerto" -ne 443 ]; then
        command -v semanage &>/dev/null && {
            semanage port -a -t http_port_t -p tcp "$puerto" &>/dev/null \
                || semanage port -m -t http_port_t -p tcp "$puerto" &>/dev/null
        }
    fi
    _configurar_firewall "$puerto" 80
    systemctl enable httpd &>/dev/null
    systemctl restart httpd
    sleep 1
    if systemctl is-active --quiet httpd; then
        echo "[OK] Apache $ver_instalada instalado y activo en el puerto $puerto."
    else
        echo "[ERROR] Apache instalado pero no pudo iniciarse. Revisa: journalctl -xe -u httpd"
    fi
}

estado_apache() {
    systemctl status httpd --no-pager -l
    echo ""
    ss -tlnp | grep -E "httpd|:80 |:8080" || echo "Apache no esta escuchando."
    local puerto_actual
    puerto_actual=$(grep "^Listen" "$APACHE_CONF" 2>/dev/null | awk '{print $2}')
    [ -n "$puerto_actual" ] && { echo ""; curl -sI "http://localhost:${puerto_actual}" | head -15; }
}

reiniciar_apache() {
    _verificar_root || return 1
    systemctl restart httpd; sleep 1
    systemctl is-active --quiet httpd && echo "[OK] Apache reiniciado." \
        || echo "[ERROR] Apache no pudo reiniciarse."
}

reconfigurar_apache() {
    _verificar_root || return 1
    rpm -q httpd &>/dev/null || { echo "[ERROR] Apache no instalado."; return 1; }
    echo "  Puerto actual: $(grep "^Listen" "$APACHE_CONF" 2>/dev/null | awk '{print $2}')"
    _leer_puerto
    local nuevo_puerto="$_PUERTO"
    sed -i "s/^Listen .*/Listen $nuevo_puerto/" "$APACHE_CONF"
    local ver_actual
    ver_actual=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' httpd)
    _crear_index_html "Apache" "$ver_actual" "$nuevo_puerto" "$APACHE_WEBROOT"
    [ "$nuevo_puerto" -ne 80 ] && [ "$nuevo_puerto" -ne 443 ] && command -v semanage &>/dev/null && {
        semanage port -a -t http_port_t -p tcp "$nuevo_puerto" &>/dev/null \
            || semanage port -m -t http_port_t -p tcp "$nuevo_puerto" &>/dev/null
    }
    _configurar_firewall "$nuevo_puerto" 80
    systemctl restart httpd; sleep 1
    systemctl is-active --quiet httpd && echo "[OK] Apache reconfigurado en el puerto $nuevo_puerto." \
        || echo "[ERROR] Apache no pudo reiniciarse."
}

_agregar_repo_nginx() {
    [ -f /etc/yum.repos.d/nginx.repo ] && return 0
    cat > /etc/yum.repos.d/nginx.repo <<'REPOEOF'
[nginx-stable]
name=nginx stable repo
baseurl=http://nginx.org/packages/centos/7/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true

[nginx-mainline]
name=nginx mainline repo
baseurl=http://nginx.org/packages/mainline/centos/7/$basearch/
gpgcheck=1
enabled=0
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
REPOEOF
    rpm --import https://nginx.org/keys/nginx_signing.key &>/dev/null
    yum clean all &>/dev/null && yum makecache fast &>/dev/null
    yum info nginx &>/dev/null 2>&1 || { echo "[ERROR] No se pudo acceder al repo nginx.org." >&2; return 1; }
    return 0
}

_obtener_versiones_nginx() {
    _agregar_repo_nginx || return 1
    local ver_stable ver_mainline versiones=""
    ver_stable=$(yum --disablerepo="*" --enablerepo="nginx-stable" \
        --showduplicates list nginx 2>/dev/null | awk '/^nginx\./{print $2}' | sort -V | tail -1)
    ver_mainline=$(yum --disablerepo="*" --enablerepo="nginx-mainline" \
        --showduplicates list nginx 2>/dev/null | awk '/^nginx\./{print $2}' | sort -V | tail -1)
    [ -n "$ver_stable"   ] && versiones+="${ver_stable} (stable)\n"
    [ -n "$ver_mainline" ] && versiones+="${ver_mainline} (mainline)"
    if [ -z "$versiones" ]; then echo "[ERROR] Sin versiones de Nginx." >&2; return 1; fi
    printf "%b" "$versiones"
}

_configurar_nginx_conf() {
    local puerto="$1"
    [ -f "$NGINX_CONF" ] && cp "$NGINX_CONF" "${NGINX_CONF}.bak.$(date +%s)"
    cat > "$NGINX_CONF" <<NGXEOF
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /tmp/nginx.pid;
events { worker_connections 1024; }
http {
    server_tokens off;
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile on;
    keepalive_timeout 65;
    server {
        listen       $puerto;
        server_name  localhost;
        root         $NGINX_WEBROOT;
        index        index.html;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-XSS-Protection "1; mode=block" always;
        if (\$request_method !~ ^(GET|POST|HEAD)\$ ) { return 405; }
        autoindex off;
        location / { try_files \$uri \$uri/ =404; }
    }
}
NGXEOF
    nginx -t &>/dev/null || cp "${NGINX_CONF}.bak."* "$NGINX_CONF" 2>/dev/null
}

instalar_nginx() {
    _verificar_root || return 1
    local versiones_raw i=1
    versiones_raw=$(_obtener_versiones_nginx)
    if [ -z "$versiones_raw" ]; then echo "[ERROR] No hay versiones de Nginx disponibles."; return 1; fi

    echo ""
    echo "  Versiones disponibles de Nginx:"
    declare -A _mapa_nginx
    while IFS= read -r ver; do
        printf "  %2d) %s\n" "$i" "$ver"
        _mapa_nginx[$i]="$ver"; ((i++))
    done <<< "$versiones_raw"
    echo ""
    local sel input
    while true; do
        read -p "  Opcion [1-$((i-1))]: " input
        input="${input//[[:space:]]/}"
        [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le $((i-1)) ] && { sel="$input"; break; }
        echo "[ERROR] Opcion invalida." >&2
    done

    _leer_puerto
    local puerto="$_PUERTO"

    yum --disablerepo="*" --enablerepo="nginx-stable,nginx-mainline" install -y nginx &>/dev/null \
        || yum install -y nginx &>/dev/null
    if ! rpm -q nginx &>/dev/null; then echo "[ERROR] Instalacion de Nginx fallida."; return 1; fi

    local ver_instalada
    ver_instalada=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' nginx)
    id nginx &>/dev/null || useradd -r -s /sbin/nologin -d "$NGINX_WEBROOT" nginx
    mkdir -p "$NGINX_WEBROOT"
    chown -R nginx:nginx "$NGINX_WEBROOT"
    chmod -R 750 "$NGINX_WEBROOT"

    systemctl stop nginx &>/dev/null
    pkill -f nginx 2>/dev/null
    sleep 1
    rm -f /run/nginx.pid /var/run/nginx.pid /run/nginx/nginx.pid /tmp/nginx.pid

    _crear_index_html "Nginx" "$ver_instalada" "$puerto" "$NGINX_WEBROOT"
    _configurar_nginx_conf "$puerto"

    if [ "$puerto" -ne 80 ] && [ "$puerto" -ne 443 ]; then
        command -v semanage &>/dev/null && {
            semanage port -a -t http_port_t -p tcp "$puerto" &>/dev/null                 || semanage port -m -t http_port_t -p tcp "$puerto" &>/dev/null
        }
    fi

    sed -i 's|PIDFile=.*|PIDFile=/tmp/nginx.pid|' /usr/lib/systemd/system/nginx.service 2>/dev/null
    systemctl daemon-reload

    _configurar_firewall "$puerto" 80
    systemctl enable nginx &>/dev/null
    systemctl start nginx; sleep 2
    if systemctl is-active --quiet nginx; then
        echo "[OK] Nginx $ver_instalada instalado y activo en el puerto $puerto."
    else
        echo "[ERROR] Nginx instalado pero no pudo iniciarse. Revisa: nginx -t"
    fi
}

estado_nginx() {
    systemctl status nginx --no-pager -l
    echo ""
    ss -tlnp | grep nginx || echo "Nginx no esta escuchando."
    local puerto_actual
    puerto_actual=$(grep -E "^\s*listen\s" "$NGINX_CONF" 2>/dev/null | awk '{print $2}' | tr -d ';' | head -1)
    [ -n "$puerto_actual" ] && { echo ""; curl -sI "http://localhost:${puerto_actual}" | head -15; }
}

reiniciar_nginx() {
    _verificar_root || return 1
    rm -f /run/nginx.pid /var/run/nginx.pid /run/nginx/nginx.pid /tmp/nginx.pid
    systemctl restart nginx; sleep 1
    systemctl is-active --quiet nginx && echo "[OK] Nginx reiniciado." \
        || echo "[ERROR] Nginx no pudo reiniciarse. Revisa: nginx -t"
}

reconfigurar_nginx() {
    _verificar_root || return 1
    rpm -q nginx &>/dev/null || { echo "[ERROR] Nginx no instalado."; return 1; }
    echo "  Puerto actual: $(grep -E "listen" "$NGINX_CONF" 2>/dev/null | awk '{print $2}' | tr -d ';' | head -1)"
    _leer_puerto
    local nuevo_puerto="$_PUERTO"
    local ver_actual
    ver_actual=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' nginx)
    _configurar_nginx_conf "$nuevo_puerto"
    _crear_index_html "Nginx" "$ver_actual" "$nuevo_puerto" "$NGINX_WEBROOT"
    chown -R nginx:nginx "$NGINX_WEBROOT"
    if [ "$nuevo_puerto" -ne 80 ] && [ "$nuevo_puerto" -ne 443 ]; then
        command -v semanage &>/dev/null && {
            semanage port -a -t http_port_t -p tcp "$nuevo_puerto" &>/dev/null                 || semanage port -m -t http_port_t -p tcp "$nuevo_puerto" &>/dev/null
        }
    fi
    _configurar_firewall "$nuevo_puerto" 80
    rm -f /run/nginx.pid /var/run/nginx.pid /run/nginx/nginx.pid /tmp/nginx.pid
    systemctl restart nginx; sleep 1
    systemctl is-active --quiet nginx && echo "[OK] Nginx reconfigurado en el puerto $nuevo_puerto." \
        || echo "[ERROR] Nginx no pudo reiniciarse."
}

_obtener_versiones_tomcat() {
    local yum_vers
    yum_vers=$(yum --showduplicates list tomcat 2>/dev/null | awk '/^tomcat\./{print $2}' | sort -Vu)
    if [ -n "$yum_vers" ]; then echo "$yum_vers"; return; fi
    local t9 t10 t11
    t9=$(curl -s --max-time 5 "https://downloads.apache.org/tomcat/tomcat-9/" \
        | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1)
    t10=$(curl -s --max-time 5 "https://downloads.apache.org/tomcat/tomcat-10/" \
        | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1)
    t11=$(curl -s --max-time 5 "https://downloads.apache.org/tomcat/tomcat-11/" \
        | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1)
    [ -z "$t9"  ] && t9="v9.0.98"
    [ -z "$t10" ] && t10="v10.1.34"
    [ -z "$t11" ] && t11="v11.0.2"
    echo "Tomcat 9  — LTS        (${t9#v})"
    echo "Tomcat 10 — Latest     (${t10#v})"
    echo "Tomcat 11 — Desarrollo (${t11#v})"
}

_url_tomcat() {
    local rama="$1"
    local base="https://downloads.apache.org/tomcat/tomcat-${rama}/"
    local ultima
    ultima=$(curl -s --max-time 5 "$base" | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1)
    if [ -z "$ultima" ]; then
        case "$rama" in
            9)  ultima="v9.0.98"  ;;
            10) ultima="v10.1.34" ;;
            11) ultima="v11.0.2"  ;;
        esac
    fi
    local version_num="${ultima#v}"
    echo "${base}${ultima}/bin/apache-tomcat-${version_num}.tar.gz"
    echo "$version_num"
}

_crear_servicio_systemd_tomcat() {
    local java_home="${1:-/usr/lib/jvm/jre}"
    cat > /etc/systemd/system/tomcat.service <<SVCEOF
[Unit]
Description=Apache Tomcat Web Application Container
After=network.target

[Service]
Type=forking
User=${TOMCAT_USER}
Group=${TOMCAT_GROUP}
Environment="JAVA_HOME=${java_home}"
Environment="CATALINA_HOME=${TOMCAT_HOME}"
Environment="CATALINA_BASE=${TOMCAT_HOME}"
Environment="CATALINA_PID=${TOMCAT_HOME}/temp/tomcat.pid"
Environment="CATALINA_OPTS=-Xms256M -Xmx512M -server -XX:+UseParallelGC"
ExecStart=${TOMCAT_HOME}/bin/startup.sh
ExecStop=${TOMCAT_HOME}/bin/shutdown.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SVCEOF
}

instalar_tomcat() {
    _verificar_root || return 1

    echo ""
    echo "  Versiones disponibles de Tomcat:"
    echo "   1) Tomcat 9  — LTS"
    echo "   2) Tomcat 10 — Latest"
    echo "   3) Tomcat 11 — Desarrollo"
    echo ""

    local rama_sel rama
    while true; do
        read -p "  Opcion [1-3]: " rama_sel
        rama_sel="${rama_sel//[[:space:]]/}"
        [[ "$rama_sel" =~ ^[123]$ ]] && break
        echo "[ERROR] Elige 1, 2 o 3." >&2
    done
    case "$rama_sel" in 1) rama=9 ;; 2) rama=10 ;; 3) rama=11 ;; esac

    _leer_puerto
    local puerto="$_PUERTO"

    command -v java &>/dev/null || yum install -y java-1.8.0-openjdk java-1.8.0-openjdk-devel &>/dev/null
    if ! command -v java &>/dev/null; then echo "[ERROR] No se pudo instalar Java."; return 1; fi

    local java_home
    java_home=$(readlink -f "$(which java)" 2>/dev/null | sed 's|/bin/java||')
    [ -z "$java_home" ] && java_home="/usr/lib/jvm/jre"

    local url_info url version_num
    url_info=$(_url_tomcat "$rama")
    url=$(echo "$url_info" | head -1)
    version_num=$(echo "$url_info" | tail -1)

    if [ -z "$version_num" ] || [ "$url" = "$version_num" ]; then
        echo "[ERROR] No se pudo obtener URL de descarga para Tomcat $rama."
        return 1
    fi

    local tmp_file="/tmp/apache-tomcat-${version_num}.tar.gz"
    wget -q "$url" -O "$tmp_file"
    if [ ! -s "$tmp_file" ]; then
        rm -f "$tmp_file"
        echo "[ERROR] Descarga fallida. URL: $url"
        return 1
    fi

    id "$TOMCAT_USER" &>/dev/null || useradd -r -s /sbin/nologin -d "$TOMCAT_HOME" "$TOMCAT_USER"

    local extracted_dir
    extracted_dir=$(tar -tzf "$tmp_file" 2>/dev/null | head -1 | cut -d'/' -f1)
    tar -xzf "$tmp_file" -C /opt/ &>/dev/null
    if [ -d "/opt/${extracted_dir}" ]; then
        rm -rf "$TOMCAT_HOME"
        mv "/opt/${extracted_dir}" "$TOMCAT_HOME"
    fi
    rm -f "$tmp_file"

    chown -R "$TOMCAT_USER:$TOMCAT_GROUP" "$TOMCAT_HOME"
    chmod -R 750 "$TOMCAT_HOME"
    chmod +x "$TOMCAT_HOME/bin/"*.sh 2>/dev/null

    sed -i "s/port=\"8080\"/port=\"$puerto\"/g" "$TOMCAT_HOME/conf/server.xml"
    sed -i 's/<Connector port="\([^"]*\)" protocol="HTTP\/1\.1"/<Connector port="\1" protocol="HTTP\/1.1" server="Apache" xpoweredBy="false"/' \
        "$TOMCAT_HOME/conf/server.xml" 2>/dev/null

    local web_xml="$TOMCAT_HOME/conf/web.xml"
    # Elimina los init-param de antiClickJacking si existen (para no duplicar)
    # e inyecta los correctos con SAMEORIGIN directo despues del filter-class
    # Primero descomenta el bloque completo del filtro y mapping si estan comentados
    perl -i -0pe 's/<!--\s*\n(\s*<filter>\s*\n\s*<filter-name>httpHeaderSecurity<\/filter-name>.*?<\/filter>\s*\n)\s*-->/$1/s' "$web_xml" 2>/dev/null
    perl -i -0pe 's/<!--\s*\n(\s*<filter-mapping>\s*\n\s*<filter-name>httpHeaderSecurity<\/filter-name>.*?<\/filter-mapping>\s*\n)\s*-->/$1/s' "$web_xml" 2>/dev/null
    # Inyecta los init-param con SAMEORIGIN despues de la linea filter-class
    sed -i 's|<filter-class>org.apache.catalina.filters.HttpHeaderSecurityFilter</filter-class>|<filter-class>org.apache.catalina.filters.HttpHeaderSecurityFilter</filter-class><init-param><param-name>antiClickJackingEnabled</param-name><param-value>true</param-value></init-param><init-param><param-name>antiClickJackingOption</param-name><param-value>SAMEORIGIN</param-value></init-param><init-param><param-name>blockContentTypeSniffingEnabled</param-name><param-value>true</param-value></init-param>|' "$web_xml" 2>/dev/null
    # Si no existe en absoluto, lo agrega antes de </web-app>
    if ! grep -q "HttpHeaderSecurityFilter" "$web_xml"; then
        sed -i 's|</web-app>|<filter><filter-name>httpHeaderSecurity</filter-name><filter-class>org.apache.catalina.filters.HttpHeaderSecurityFilter</filter-class><init-param><param-name>antiClickJackingEnabled</param-name><param-value>true</param-value></init-param><init-param><param-name>antiClickJackingOption</param-name><param-value>SAMEORIGIN</param-value></init-param><init-param><param-name>blockContentTypeSniffingEnabled</param-name><param-value>true</param-value></init-param></filter><filter-mapping><filter-name>httpHeaderSecurity</filter-name><url-pattern>/*</url-pattern></filter-mapping></web-app>|' "$web_xml"
    fi

    _crear_index_html "Tomcat" "$version_num" "$puerto" "$TOMCAT_HOME/webapps/ROOT"
    chown "$TOMCAT_USER:$TOMCAT_GROUP" "$TOMCAT_HOME/webapps/ROOT/index.html"
    _crear_servicio_systemd_tomcat "$java_home"
    _configurar_firewall "$puerto" 8080
    systemctl daemon-reload
    systemctl enable tomcat &>/dev/null
    systemctl start tomcat
    sleep 10
    if systemctl is-active --quiet tomcat; then
        echo "[OK] Tomcat $version_num instalado y activo en el puerto $puerto."
    else
        echo "[ERROR] Tomcat instalado pero no pudo iniciarse."
        echo "        Log: tail -20 $TOMCAT_HOME/logs/catalina.out"
    fi
}

estado_tomcat() {
    systemctl status tomcat --no-pager -l
    echo ""
    ss -tlnp | grep java || echo "Tomcat no esta escuchando."
    local puerto_actual
    puerto_actual=$(grep -oP 'port="\K[0-9]+' "$TOMCAT_HOME/conf/server.xml" 2>/dev/null | head -1)
    [ -n "$puerto_actual" ] && { echo ""; curl -sI "http://localhost:${puerto_actual}" | head -15; }
    echo ""
    tail -10 "$TOMCAT_HOME/logs/catalina.out" 2>/dev/null
}

reiniciar_tomcat() {
    _verificar_root || return 1
    systemctl restart tomcat; sleep 5
    systemctl is-active --quiet tomcat && echo "[OK] Tomcat reiniciado." \
        || echo "[ERROR] Tomcat no pudo reiniciarse."
}

reconfigurar_tomcat() {
    _verificar_root || return 1
    [ -d "$TOMCAT_HOME" ] || { echo "[ERROR] Tomcat no instalado en $TOMCAT_HOME."; return 1; }
    local puerto_viejo
    puerto_viejo=$(grep -oP 'port="\K[0-9]+' "$TOMCAT_HOME/conf/server.xml" 2>/dev/null | head -1)
    echo "  Puerto actual: $puerto_viejo"
    _leer_puerto
    local nuevo_puerto="$_PUERTO"
    sed -i "s/port=\"${puerto_viejo}\"/port=\"${nuevo_puerto}\"/g" "$TOMCAT_HOME/conf/server.xml"
    local ver_actual
    ver_actual=$(grep -oP '(?<=Apache Tomcat Version )[^\s]+' "$TOMCAT_HOME/RELEASE-NOTES" 2>/dev/null | head -1)
    [ -z "$ver_actual" ] && ver_actual="desconocida"
    _crear_index_html "Tomcat" "$ver_actual" "$nuevo_puerto" "$TOMCAT_HOME/webapps/ROOT"
    chown "$TOMCAT_USER:$TOMCAT_GROUP" "$TOMCAT_HOME/webapps/ROOT/index.html"
    _configurar_firewall "$nuevo_puerto" 8080
    systemctl restart tomcat; sleep 8
    systemctl is-active --quiet tomcat && echo "[OK] Tomcat reconfigurado en el puerto $nuevo_puerto." \
        || echo "[ERROR] Tomcat no pudo reiniciarse."
}
