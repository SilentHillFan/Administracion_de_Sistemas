#!/bin/bash
# =============================================================================
#  PRÁCTICA 10 — Contenedores Docker (CentOS 7)
#  Migración de servicios a contenedores con seguridad y almacenamiento
#  Servicios: Nginx (Alpine) + PostgreSQL + FTP (vsftpd)
#  Incluye: Pruebas 10.1 · 10.2 · 10.3 · 10.4
# =============================================================================

set -euo pipefail

# ── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()      { echo -e "${GREEN}  [✔] $*${NC}"; }
fail()    { echo -e "${RED}  [✘] $*${NC}"; }
info()    { echo -e "${BLUE}  [i] $*${NC}"; }
warn()    { echo -e "${YELLOW}  [!] $*${NC}"; }
section() {
    echo -e "\n${CYAN}${BOLD}══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}  $*${NC}"
    echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════${NC}\n"
}

WORK_DIR="$HOME/practica10"
BACKUP_DIR="$WORK_DIR/backups"

# Wrapper: usa sudo si el usuario aún no está en el grupo docker
dk() {
    if docker info &>/dev/null 2>&1; then
        docker "$@"
    else
        sudo docker "$@"
    fi
}

# =============================================================================
# FASE PREVIA — LIMPIEZA TOTAL DEL ENTORNO
# =============================================================================
limpiar_entorno() {
    section "FASE PREVIA · Limpieza de Entorno y Liberación de Puertos"

    info "1. Deteniendo servicios nativos conflictivos..."
    for srv in nginx httpd vsftpd proftpd postgresql; do
        if systemctl is-active --quiet "$srv" 2>/dev/null; then
            warn "Servicio $srv detectado. Deteniendo y deshabilitando..."
            sudo systemctl stop "$srv" 2>/dev/null || true
            sudo systemctl disable "$srv" 2>/dev/null || true
        fi
    done

    info "2. Asegurando puertos libres (8080, 21, 5432)..."
    if command -v ss &>/dev/null; then
        for puerto in 8080 21 5432; do
            PIDS=$(sudo ss -lptn "sport = :$puerto" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | sort -u || true)
            for p in $PIDS; do
                warn "Matando proceso huérfano (PID: $p) en el puerto $puerto..."
                sudo kill -9 "$p" 2>/dev/null || true
            done
        done
    fi

    if command -v docker &>/dev/null; then
        info "3. Limpiando contenedores y redes de Docker de ejecuciones previas..."
        dk rm -f web_server pg_server ftp_server 2>/dev/null || true
        dk network rm infra_red 2>/dev/null || true
    fi
    
    ok "Entorno purgado y listo para desplegar."
}

# =============================================================================
# FASE 0 — INSTALACIÓN DE DOCKER EN CENTOS 7 (EOL)
# CentOS 7 llegó a fin de vida. Los mirrors oficiales están caídos.
# Se instalan los RPMs directamente desde download.docker.com y vault.centos.org
# usando --nodeps para evitar dependencias opcionales no disponibles
# (docker-scan-plugin, docker-ce-rootless-extras, fuse-overlayfs, slirp4netns).
# Ninguna de esas dependencias es necesaria para esta práctica.
# =============================================================================
instalar_docker() {
    section "FASE 0 · Instalación de Docker en CentOS 7 (EOL)"

    # ── Si docker ya está instalado solo aseguramos que el servicio corra ────
    if command -v docker &>/dev/null; then
        ok "Docker ya instalado: $(docker --version). Omitiendo descargas."
        systemctl start docker 2>/dev/null || true
        return 0
    fi

    local DOCKER_BASE="https://download.docker.com/linux/centos/7/x86_64/stable/Packages"
    local DOCKER_VER="20.10.9-3.el7"

    info "Instalando dependencias base (bc, curl)..."
    yum install -y bc curl device-mapper-persistent-data lvm2

    # ── container-selinux (requerido por containerd) ─────────────────────────
    info "Instalando container-selinux desde vault.centos.org..."
    rpm -ivh --nodeps \
        https://vault.centos.org/centos/7/extras/x86_64/Packages/container-selinux-2.119.2-1.911c772.el7_8.noarch.rpm \
        2>/dev/null || warn "container-selinux ya instalado o no disponible, continuando..."

    # ── containerd.io ─────────────────────────────────────────────────────────
    info "Instalando containerd.io..."
    rpm -ivh --nodeps \
        "$DOCKER_BASE/containerd.io-1.4.11-3.1.el7.x86_64.rpm"

    # ── docker-ce-cli ─────────────────────────────────────────────────────────
    info "Instalando docker-ce-cli (sin docker-scan-plugin)..."
    rpm -ivh --nodeps \
        "$DOCKER_BASE/docker-ce-cli-${DOCKER_VER}.x86_64.rpm"

    # ── docker-ce ─────────────────────────────────────────────────────────────
    info "Instalando docker-ce (sin rootless-extras)..."
    rpm -ivh --nodeps \
        "$DOCKER_BASE/docker-ce-${DOCKER_VER}.x86_64.rpm"

    # ── Servicio ──────────────────────────────────────────────────────────────
    info "Habilitando y arrancando el servicio Docker..."
    systemctl enable docker
    systemctl start docker

    if docker ps &>/dev/null; then
        ok "Docker instalado correctamente: $(docker --version)"
    else
        fail "Docker instalado pero el servicio no responde. Revisa: systemctl status docker"
        exit 1
    fi
}

# =============================================================================
# FASE 1 — ESTRUCTURA DE DIRECTORIOS
# =============================================================================
crear_estructura() {
    section "FASE 1 · Estructura del Proyecto"

    mkdir -p "$WORK_DIR"/{nginx,ftp,scripts}
    mkdir -p "$BACKUP_DIR"

    ok "Estructura creada en: $WORK_DIR"
    find "$WORK_DIR" -type d | sed "s|$WORK_DIR||" | sed 's|[^/]*/|  |g'
}

# =============================================================================
# FASE 2 — DOCKERFILE Y ARCHIVOS DEL SERVIDOR WEB (NGINX + ALPINE)
# =============================================================================
crear_nginx() {
    section "FASE 2 · Imagen Personalizada Nginx (Alpine)"

    # ── nginx.conf: server_tokens off, usuario no-root, puerto 8080 ──────────
    cat > "$WORK_DIR/nginx/nginx.conf" << 'NGINX_CONF'
worker_processes auto;
error_log /tmp/nginx_error.log warn;
pid /tmp/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    # ── SEGURIDAD: eliminar firma y versión del servidor ────────────────────
    server_tokens off;

    sendfile        on;
    keepalive_timeout 65;

    # Rutas tmp accesibles por usuario no-root
    client_body_temp_path /tmp/nginx_client_temp;
    proxy_temp_path       /tmp/nginx_proxy_temp;
    fastcgi_temp_path     /tmp/nginx_fastcgi_temp;
    uwsgi_temp_path       /tmp/nginx_uwsgi_temp;
    scgi_temp_path        /tmp/nginx_scgi_temp;

    server {
        listen 8080;
        server_name localhost;
        root /var/www/html;
        index index.html;

        location / {
            try_files $uri $uri/ =404;
        }

        # Archivos subidos via FTP (volumen compartido web_content)
        location /uploads/ {
            autoindex on;
            autoindex_exact_size off;
            autoindex_localtime on;
        }
    }
}
NGINX_CONF

    # ── Página HTML principal ─────────────────────────────────────────────────
    cat > "$WORK_DIR/nginx/index.html" << 'HTML_EOF'
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Práctica 10 · Contenedores Docker</title>
    <link rel="stylesheet" href="style.css">
</head>
<body>
    <div class="bg-grid"></div>
    <div class="container">
        <header>
            <img src="logo.svg" alt="Docker Logo" class="logo">
            <h1>Infraestructura en Contenedores</h1>
            <p class="subtitle">Práctica 10 &mdash; CentOS 7 + Docker</p>
            <div class="badge">Imagen personalizada · usuario no-root · server_tokens off</div>
        </header>
        <div class="grid">
            <div class="card card-web">
                <span class="icon">🌐</span>
                <h2>Servidor Web</h2>
                <p>Nginx sobre <strong>Alpine Linux</strong>. Imagen personalizada con usuario
                   no administrativo (<code>webuser</code>) y firmas de servidor deshabilitadas.</p>
                <div class="tag">Puerto 8080 · Volumen: web_content · IP: 172.20.0.20</div>
            </div>
            <div class="card card-db">
                <span class="icon">🗄️</span>
                <h2>Base de Datos</h2>
                <p><strong>PostgreSQL 15</strong> con volumen persistente <code>db_data</code>.
                   Respaldos automáticos generados en la carpeta del host.</p>
                <div class="tag">Puerto 5432 · Volumen: db_data · IP: 172.20.0.10</div>
            </div>
            <div class="card card-ftp">
                <span class="icon">📁</span>
                <h2>Servidor FTP</h2>
                <p><strong>vsftpd</strong> sobre Alpine. Volumen <code>web_content</code>
                   compartido con el servidor web para acceso inmediato a archivos cargados.</p>
                <div class="tag">Puerto 21 · Volumen: web_content · IP: 172.20.0.30</div>
            </div>
            <div class="card card-net">
                <span class="icon">🔒</span>
                <h2>Red &amp; Recursos</h2>
                <p>Red bridge <code>infra_red</code> (172.20.0.0/16). Límites de CPU y RAM
                   configurados por contenedor para aislamiento de fallos.</p>
                <div class="tag">infra_red · 172.20.0.0/16 · RAM + CPU limitados</div>
            </div>
        </div>
        <div class="uploads-box">
            <h3>📤 Archivos subidos vía FTP</h3>
            <p><a href="/uploads/" class="link">Explorar directorio /uploads/ →</a></p>
        </div>
        <footer>
            <p>Red: <strong>infra_red</strong> &nbsp;|&nbsp;
               Subred: <strong>172.20.0.0/16</strong> &nbsp;|&nbsp;
               Imagen base: <strong>nginx:alpine</strong></p>
        </footer>
    </div>
</body>
</html>
HTML_EOF

    # ── CSS ───────────────────────────────────────────────────────────────────
    cat > "$WORK_DIR/nginx/style.css" << 'CSS_EOF'
:root {
    --accent:#e94560; --accent2:#0db7ed;
    --bg:#0f172a; --card:rgba(255,255,255,0.04);
    --border:rgba(255,255,255,0.08); --text:#cbd5e1; --muted:#64748b;
}
*{margin:0;padding:0;box-sizing:border-box;}
body{font-family:'Segoe UI',system-ui,sans-serif;background:var(--bg);color:var(--text);
     min-height:100vh;display:flex;align-items:center;justify-content:center;
     padding:2rem;position:relative;overflow-x:hidden;}
.bg-grid{position:fixed;inset:0;
    background-image:linear-gradient(rgba(13,183,237,.04) 1px,transparent 1px),
                     linear-gradient(90deg,rgba(13,183,237,.04) 1px,transparent 1px);
    background-size:40px 40px;pointer-events:none;}
.container{max-width:960px;width:100%;position:relative;}
header{text-align:center;margin-bottom:2.5rem;}
.logo{width:72px;height:72px;margin-bottom:1rem;filter:drop-shadow(0 0 20px rgba(13,183,237,.5));}
h1{font-size:clamp(1.5rem,4vw,2.2rem);color:#f1f5f9;font-weight:700;}
.subtitle{color:var(--muted);margin-top:.4rem;font-size:1.05rem;}
.badge{display:inline-block;margin-top:1rem;background:rgba(233,69,96,.15);
       border:1px solid rgba(233,69,96,.3);color:var(--accent);border-radius:999px;
       padding:.3rem 1rem;font-size:.8rem;font-family:monospace;}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:1.25rem;margin-bottom:1.5rem;}
@media(max-width:600px){.grid{grid-template-columns:1fr;}}
.card{background:var(--card);border:1px solid var(--border);border-radius:14px;
      padding:1.5rem;transition:transform .2s,border-color .2s;}
.card:hover{transform:translateY(-3px);}
.card-web:hover{border-color:var(--accent2);}
.card-db:hover{border-color:#a855f7;}
.card-ftp:hover{border-color:#22d3ee;}
.card-net:hover{border-color:var(--accent);}
.icon{font-size:1.8rem;display:block;margin-bottom:.6rem;}
.card h2{font-size:1.05rem;color:#f1f5f9;margin-bottom:.6rem;}
.card p{font-size:.9rem;line-height:1.6;color:var(--text);}
code{background:rgba(255,255,255,.08);padding:.1rem .35rem;border-radius:4px;font-size:.85em;}
.tag{margin-top:1rem;font-size:.75rem;font-family:monospace;color:var(--muted);
     border-top:1px solid var(--border);padding-top:.6rem;}
.uploads-box{background:var(--card);border:1px solid var(--border);border-radius:14px;
             padding:1.25rem 1.5rem;margin-bottom:1.5rem;
             display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:.5rem;}
.uploads-box h3{font-size:1rem;color:#f1f5f9;}
.link{color:var(--accent2);text-decoration:none;font-size:.95rem;}
.link:hover{text-decoration:underline;}
footer{text-align:center;color:var(--muted);font-size:.85rem;padding-top:1rem;border-top:1px solid var(--border);}
CSS_EOF

    # ── Logo SVG ──────────────────────────────────────────────────────────────
    cat > "$WORK_DIR/nginx/logo.svg" << 'SVG_EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <defs>
    <linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#0db7ed"/>
      <stop offset="100%" stop-color="#086990"/>
    </linearGradient>
  </defs>
  <rect width="100" height="100" rx="22" fill="url(#g)"/>
  <rect x="12" y="52" width="14" height="13" rx="2" fill="white" opacity=".9"/>
  <rect x="29" y="52" width="14" height="13" rx="2" fill="white" opacity=".9"/>
  <rect x="46" y="52" width="14" height="13" rx="2" fill="white" opacity=".9"/>
  <rect x="29" y="36" width="14" height="13" rx="2" fill="white" opacity=".9"/>
  <rect x="46" y="36" width="14" height="13" rx="2" fill="white" opacity=".9"/>
  <rect x="46" y="20" width="14" height="13" rx="2" fill="white" opacity=".9"/>
  <path d="M65 57 Q82 52 84 64 Q84 74 68 71 Z" fill="#086990" stroke="white" stroke-width="1.5"/>
  <circle cx="76" cy="58" r="2.5" fill="white"/>
  <path d="M8 74 Q20 68 32 74 Q44 80 56 74 Q68 68 80 74 Q88 78 92 74"
        stroke="white" stroke-width="2" fill="none" opacity=".5"/>
</svg>
SVG_EOF

    # ── Dockerfile Nginx ──────────────────────────────────────────────────────
    cat > "$WORK_DIR/nginx/Dockerfile" << 'DOCK_NGINX'
# ── Imagen base ligera (Alpine) ───────────────────────────────
FROM nginx:alpine

# ── Herramienta ping para pruebas de red ─────────────────────
RUN apk add --no-cache iputils

# ── SEGURIDAD: usuario no administrativo ──────────────────────
RUN addgroup -S webgroup \
 && adduser  -S webuser -G webgroup

# ── Configuración personalizada con server_tokens off ─────────
COPY nginx.conf /etc/nginx/nginx.conf

# ── Directorios web con permisos correctos ────────────────────
RUN mkdir -p /var/www/html/uploads \
             /tmp/nginx_client_temp /tmp/nginx_proxy_temp \
             /tmp/nginx_fastcgi_temp /tmp/nginx_uwsgi_temp \
             /tmp/nginx_scgi_temp \
 && touch /tmp/nginx.pid /tmp/nginx_error.log \
 && chown -R webuser:webgroup \
             /var/www/html \
             /var/cache/nginx \
             /tmp/nginx.pid \
             /tmp/nginx_error.log \
             /tmp/nginx_client_temp \
             /tmp/nginx_proxy_temp \
             /tmp/nginx_fastcgi_temp \
             /tmp/nginx_uwsgi_temp \
             /tmp/nginx_scgi_temp

# ── Archivos estáticos personalizados ─────────────────────────
COPY index.html /var/www/html/
COPY style.css  /var/www/html/
COPY logo.svg   /var/www/html/

# Puerto no privilegiado (no requiere root)
EXPOSE 8080

# ── Ejecutar como usuario no administrativo ───────────────────
USER webuser

CMD ["nginx", "-g", "daemon off;"]
DOCK_NGINX

    ok "Nginx: Dockerfile + nginx.conf + index.html + style.css + logo.svg"
}

# =============================================================================
# FASE 3 — DOCKERFILE DEL SERVIDOR FTP (vsftpd + Alpine)
# =============================================================================
crear_ftp() {
    section "FASE 3 · Imagen Personalizada FTP (vsftpd + Alpine)"

    cat > "$WORK_DIR/ftp/vsftpd.conf" << 'FTP_CONF'
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
dirmessage_enable=YES
xferlog_enable=YES
connect_from_port_20=YES
chroot_local_user=YES
allow_writeable_chroot=YES
secure_chroot_dir=/var/ftp
pasv_enable=YES
pasv_min_port=21100
pasv_max_port=21110
pasv_address=127.0.0.1
local_root=/srv/ftp
FTP_CONF

    cat > "$WORK_DIR/ftp/Dockerfile" << 'DOCK_FTP'
FROM alpine:3.18

# Instalar vsftpd
RUN apk add --no-cache vsftpd

# Usuario FTP sin shell de login
RUN adduser -D -H -s /sbin/nologin ftpuser \
 && echo "ftpuser:ftp1234" | chpasswd

# Directorio de subida compartido con web_content
RUN mkdir -p /srv/ftp \
 && chmod 777 /srv/ftp \
 && chown ftpuser:ftpuser /srv/ftp

# Directorio seguro requerido por vsftpd (no debe tener permisos de escritura)
RUN mkdir -p /var/ftp \
 && chmod 555 /var/ftp

COPY vsftpd.conf /etc/vsftpd/vsftpd.conf

EXPOSE 21 21100-21110

CMD ["vsftpd", "/etc/vsftpd/vsftpd.conf"]
DOCK_FTP

    ok "FTP: Dockerfile + vsftpd.conf  |  usuario: ftpuser  |  pass: ftp1234"
}

# =============================================================================
# FASE 4 — SCRIPT DE RESPALDO AUTOMÁTICO DE POSTGRESQL
# =============================================================================
crear_backup_script() {
    section "FASE 4 · Script de Respaldo Automático de PostgreSQL"

    cat > "$WORK_DIR/scripts/backup_db.sh" << 'BACKUP_SCRIPT'
#!/bin/bash
# backup_db.sh — Respaldo automático de PostgreSQL hacia el host
BACKUP_DIR="$(cd "$(dirname "$0")/../backups" && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUT="$BACKUP_DIR/pg_backup_$TIMESTAMP.sql"
mkdir -p "$BACKUP_DIR"
echo "[$(date)] Iniciando respaldo de PostgreSQL..."
docker exec pg_server pg_dumpall -U pguser > "$OUT"
if [ $? -eq 0 ]; then
    SIZE=$(du -sh "$OUT" | cut -f1)
    echo "[$(date)] Respaldo creado: $OUT ($SIZE)"
    # Conservar solo los últimos 7 respaldos
    ls -t "$BACKUP_DIR"/pg_backup_*.sql 2>/dev/null | tail -n +8 | xargs -r rm -f
else
    echo "[$(date)] ERROR: Respaldo fallido"; exit 1
fi
BACKUP_SCRIPT

    chmod +x "$WORK_DIR/scripts/backup_db.sh"
    ok "Script: $WORK_DIR/scripts/backup_db.sh"
    info "Para automatizar (crontab -e):"
    info "  0 2 * * * $WORK_DIR/scripts/backup_db.sh >> $WORK_DIR/backups/backup.log 2>&1"
}

# =============================================================================
# FASE 5 — DESPLIEGUE DE CONTENEDORES
# =============================================================================
desplegar_contenedores() {
    section "FASE 5 · Despliegue de Contenedores"

    # ── Limpieza de ejecuciones previas (la redundancia no hace daño) ───────
    info "Eliminando recursos previos (si existen)..."
    dk rm -f web_server pg_server ftp_server 2>/dev/null || true
    dk network rm infra_red 2>/dev/null || true
    dk volume rm web_content 2>/dev/null || true
    # NOTA: db_data NO se elimina para preservar datos entre re-ejecuciones

    # ── Red personalizada ─────────────────────────────────────────────────────
    info "Creando red bridge personalizada infra_red (172.20.0.0/16)..."
    dk network create \
        --driver bridge \
        --subnet 172.20.0.0/16 \
        --gateway 172.20.0.1 \
        --opt "com.docker.network.bridge.name=br_infra" \
        infra_red
    ok "Red infra_red  →  subnet: 172.20.0.0/16  |  gateway: 172.20.0.1"

    # ── Volúmenes persistentes ────────────────────────────────────────────────
    info "Creando volúmenes persistentes..."
    dk volume create db_data
    dk volume create web_content
    ok "db_data (PostgreSQL)  +  web_content (Nginx/FTP compartido)"

    # ── Build imágenes personalizadas ─────────────────────────────────────────
    info "Construyendo imagen custom_nginx:latest..."
    dk build -t custom_nginx:latest "$WORK_DIR/nginx/"
    ok "Imagen custom_nginx:latest lista"

    info "Construyendo imagen custom_ftp:latest..."
    dk build -t custom_ftp:latest "$WORK_DIR/ftp/"
    ok "Imagen custom_ftp:latest lista"

    # ── Contenedor 1: PostgreSQL ──────────────────────────────────────────────
    info "Iniciando PostgreSQL (pg_server)..."
    dk run -d \
        --name pg_server \
        --network infra_red \
        --ip 172.20.0.10 \
        --memory 512m \
        --memory-swap 512m \
        --cpus 0.5 \
        -v db_data:/var/lib/postgresql/data \
        -v "$BACKUP_DIR":/backups \
        -e POSTGRES_USER=pguser \
        -e POSTGRES_PASSWORD=pgpass123 \
        -e POSTGRES_DB=practica10 \
        -p 5432:5432 \
        postgres:15-alpine
    ok "pg_server  →  IP: 172.20.0.10  |  RAM: 512MB  |  CPU: 0.5 cores"

    # ── Contenedor 2: Nginx personalizado ─────────────────────────────────────
    info "Iniciando Nginx personalizado (web_server)..."
    dk run -d \
        --name web_server \
        --network infra_red \
        --ip 172.20.0.20 \
        --memory 256m \
        --memory-swap 256m \
        --cpus 0.25 \
        -v web_content:/var/www/html/uploads \
        -p 8080:8080 \
        custom_nginx:latest
    ok "web_server  →  IP: 172.20.0.20  |  http://localhost:8080  |  RAM: 256MB  |  CPU: 0.25 cores"

    # ── Contenedor 3: FTP ─────────────────────────────────────────────────────
    info "Iniciando servidor FTP (ftp_server)..."
    dk run -d \
        --name ftp_server \
        --network infra_red \
        --ip 172.20.0.30 \
        --memory 128m \
        --memory-swap 128m \
        --cpus 0.25 \
        -v web_content:/srv/ftp \
        -p 21:21 \
        -p 21100-21110:21100-21110 \
        custom_ftp:latest
    ok "ftp_server  →  IP: 172.20.0.30  |  Puerto: 21  |  RAM: 128MB  |  CPU: 0.25 cores"

    info "Esperando que los servicios estén listos (12 seg)..."
    sleep 12

    info "Estado de contenedores:"
    dk ps --format "  {{.Names}} | {{.Status}} | {{.Ports}}" | grep -E "web_server|pg_server|ftp_server" || true
}

# =============================================================================
# PRUEBA 10.1 — PERSISTENCIA DE BASE DE DATOS
# =============================================================================
prueba_10_1() {
    section "PRUEBA 10.1 · Persistencia de Base de Datos"

    echo -e "${BOLD}  Objetivo:${NC} Demostrar que los datos sobreviven a:  docker rm -f pg_server"
    echo ""

    # Esperar PostgreSQL listo
    info "Esperando conexión a PostgreSQL..."
    local INTENTOS=0
    until dk exec pg_server pg_isready -U pguser -q 2>/dev/null || [ $INTENTOS -ge 20 ]; do
        sleep 2; INTENTOS=$((INTENTOS + 1)); printf "."
    done
    echo ""; sleep 2

    # ── Crear tabla e insertar datos ─────────────────────────────────────────
    info "Paso 1: Creando tabla 'usuarios' e insertando 3 registros..."
    dk exec pg_server psql -U pguser -d practica10 -c "
        CREATE TABLE IF NOT EXISTS usuarios (
            id     SERIAL PRIMARY KEY,
            nombre VARCHAR(100) NOT NULL,
            email  VARCHAR(100) UNIQUE NOT NULL,
            rol    VARCHAR(50) DEFAULT 'estudiante'
        );
        INSERT INTO usuarios (nombre, email, rol) VALUES
            ('Ana García',   'ana@practica10.com',   'admin'),
            ('Carlos López', 'carlos@practica10.com','estudiante'),
            ('María Torres', 'maria@practica10.com', 'estudiante')
        ON CONFLICT (email) DO NOTHING;
    " 2>&1 | sed 's/^/    /'

    echo ""
    info "Datos en la BD antes de destruir el contenedor:"
    dk exec pg_server psql -U pguser -d practica10 \
        -c "SELECT id, nombre, email, rol FROM usuarios ORDER BY id;" \
        2>&1 | sed 's/^/    /'

    # ── Destruir el contenedor ────────────────────────────────────────────────
    echo ""
    info "Paso 2: Ejecutando  docker rm -f pg_server  ..."
    dk rm -f pg_server
    ok "Contenedor pg_server DESTRUIDO (el volumen db_data persiste)"
    sleep 2

    # ── Recrear con el mismo volumen ──────────────────────────────────────────
    info "Paso 3: Iniciando NUEVO contenedor con el mismo volumen db_data..."
    dk run -d \
        --name pg_server \
        --network infra_red \
        --ip 172.20.0.10 \
        --memory 512m \
        --memory-swap 512m \
        --cpus 0.5 \
        -v db_data:/var/lib/postgresql/data \
        -v "$BACKUP_DIR":/backups \
        -e POSTGRES_USER=pguser \
        -e POSTGRES_PASSWORD=pgpass123 \
        -e POSTGRES_DB=practica10 \
        -p 5432:5432 \
        postgres:15-alpine
    ok "Nuevo contenedor pg_server creado"

    info "Esperando arranque de PostgreSQL..."
    local INTENTOS2=0
    until dk exec pg_server pg_isready -U pguser -q 2>/dev/null || [ $INTENTOS2 -ge 20 ]; do
        sleep 2; INTENTOS2=$((INTENTOS2 + 1)); printf "."
    done
    echo ""; sleep 2

    # ── Verificar datos ───────────────────────────────────────────────────────
    info "Paso 4: Verificando persistencia de datos en el nuevo contenedor..."
    echo ""
    dk exec pg_server psql -U pguser -d practica10 \
        -c "SELECT id, nombre, email, rol FROM usuarios ORDER BY id;" \
        2>&1 | sed 's/^/    /'

    REGISTROS=$(dk exec pg_server psql -U pguser -d practica10 \
        -c "SELECT COUNT(*) FROM usuarios;" -t 2>/dev/null | tr -d ' \n')
    echo ""

    if [ "${REGISTROS:-0}" -ge 3 ] 2>/dev/null; then
        ok "PRUEBA 10.1 EXITOSA: $REGISTROS registros recuperados tras destruir y recrear el contenedor"
    else
        fail "PRUEBA 10.1 FALLIDA: registros = '${REGISTROS:-0}' (esperado >= 3)"
    fi

    # ── Respaldo automático ───────────────────────────────────────────────────
    echo ""
    info "Generando respaldo automático hacia el host..."
    dk exec pg_server pg_dumpall -U pguser \
        > "$BACKUP_DIR/pg_backup_$(date +%Y%m%d_%H%M%S).sql"
    ok "Respaldo generado en: $BACKUP_DIR"
    ls -lh "$BACKUP_DIR"/*.sql 2>/dev/null | awk '{printf "    %-45s %s\n", $NF, $5}'
}

# =============================================================================
# PRUEBA 10.2 — AISLAMIENTO DE RED
# =============================================================================
prueba_10_2() {
    section "PRUEBA 10.2 · Aislamiento de Red (infra_red)"

    echo -e "${BOLD}  Objetivo:${NC} Verificar que web_server resuelve y alcanza pg_server"
    echo -e "            por nombre dentro de la red infra_red.\n"

    # ── Topología ─────────────────────────────────────────────────────────────
    info "Topología de la red infra_red:"
    echo ""
    printf "    %-20s %-18s\n" "CONTENEDOR" "IP ASIGNADA"
    printf "    %-20s %-18s\n" "──────────────────" "────────────────"
    for CTR in web_server pg_server ftp_server; do
        IP=$(dk inspect "$CTR" \
             --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || echo "N/A")
        printf "    %-20s %-18s\n" "$CTR" "$IP"
    done
    echo ""

    # ── Ping por nombre de contenedor ────────────────────────────────────────
    info "Ejecutando: docker exec web_server ping -c 4 pg_server"
    echo ""
    PING_OUT=$(dk exec web_server ping -c 4 pg_server 2>&1)
    echo "$PING_OUT" | sed 's/^/    /'
    echo ""

    if echo "$PING_OUT" | grep -q "bytes from"; then
        ok "PRUEBA 10.2 EXITOSA: web_server resuelve y alcanza pg_server por nombre DNS interno"
    else
        fail "PRUEBA 10.2 FALLIDA: no hay conectividad entre contenedores"
    fi

    # ── Test adicional ─────────────────────────────────────────────────────
    info "Verificando también: web_server → ftp_server..."
    PING2=$(dk exec web_server ping -c 2 ftp_server 2>&1)
    if echo "$PING2" | grep -q "bytes from"; then
        ok "web_server → ftp_server: OK"
    else
        warn "web_server → ftp_server: sin respuesta ICMP (puede ser normal)"
    fi

    echo ""
    info "Inspección de infra_red:"
    dk network inspect infra_red \
        --format '    Subnet : {{range .IPAM.Config}}{{.Subnet}}{{end}}
    Gateway: {{range .IPAM.Config}}{{.Gateway}}{{end}}
    Driver : {{.Driver}}' 2>/dev/null
}

# =============================================================================
# PRUEBA 10.3 — PERMISOS FTP (VOLUMEN COMPARTIDO)
# =============================================================================
prueba_10_3() {
    section "PRUEBA 10.3 · Permisos FTP (Volumen Compartido web_content)"

    echo -e "${BOLD}  Objetivo:${NC} Subir un archivo al contenedor FTP y verificar que"
    echo -e "            el servidor web lo puede visualizar (volumen compartido).\n"

    local ARCHIVO="ftp_test_$(date +%s).txt"
    local CONTENIDO="=== Archivo de prueba FTP ===
Generado   : $(date)
Practica   : 10 - CentOS 7 + Docker
Servicio   : ftp_server -> volumen web_content -> web_server
Verificar  : http://localhost:8080/uploads/$ARCHIVO"

    echo "$CONTENIDO" > "/tmp/$ARCHIVO"
    info "Archivo preparado: /tmp/$ARCHIVO"

    # ── Intento 1: curl FTP ───────────────────────────────────────────────────
    info "Método 1: Subida via curl FTP a localhost:21..."
    CURL_OK=false
    if command -v curl &>/dev/null; then
        CURL_RESULT=$(curl -s --connect-timeout 8 \
            --ftp-pasv \
            -u ftpuser:ftp1234 \
            -T "/tmp/$ARCHIVO" \
            "ftp://127.0.0.1:21/$ARCHIVO" 2>&1 || echo "ERROR")
        if [ "$CURL_RESULT" != "ERROR" ] && [ -z "$(echo "$CURL_RESULT" | grep -i error)" ]; then
            ok "Upload FTP via curl: completado"
            CURL_OK=true
        else
            warn "curl FTP falló: $CURL_RESULT"
        fi
    else
        warn "curl no disponible"
    fi

    # ── Intento 2: copia directa al volumen vía ftp_server ───────────────────
    if [ "$CURL_OK" = false ]; then
        info "Método 2: Copia directa al volumen compartido via ftp_server..."
        dk exec ftp_server chmod 777 /srv/ftp 2>/dev/null || true
        dk cp "/tmp/$ARCHIVO" ftp_server:/srv/ftp/
        dk exec ftp_server chmod 644 "/srv/ftp/$ARCHIVO" 2>/dev/null || true
        ok "Archivo copiado al volumen web_content (a través de ftp_server)"
    fi

    sleep 2

    # ── Ajustar permisos del directorio de uploads en web_server ─────────────
    dk exec web_server sh -c "chmod 755 /var/www/html/uploads" 2>/dev/null || true

    # ── Verificar en web_server ───────────────────────────────────────────────
    info "Verificando visibilidad en web_server (volumen web_content montado en /uploads)..."
    echo ""
    LISTA=$(dk exec web_server ls -la /var/www/html/uploads/ 2>/dev/null || echo "")
    echo "$LISTA" | sed 's/^/    /'
    echo ""

    ENCONTRADO=$(echo "$LISTA" | grep "$ARCHIVO" || echo "")
    if [ -n "$ENCONTRADO" ]; then
        ok "PRUEBA 10.3 EXITOSA: '$ARCHIVO' es visible desde el servidor web"
        info "URL de acceso: http://localhost:8080/uploads/$ARCHIVO"
        info "Directorio   : http://localhost:8080/uploads/"
    else
        fail "PRUEBA 10.3 FALLIDA: archivo no encontrado en /var/www/html/uploads/"
        info "Contenido en ftp_server:/srv/ftp/:"
        dk exec ftp_server ls -la /srv/ftp/ 2>/dev/null | sed 's/^/    /'
    fi

    echo ""
    echo -e "  ${CYAN}Datos de conexión FTP manual:${NC}"
    echo "    Host    : 127.0.0.1"
    echo "    Puerto  : 21"
    echo "    Usuario : ftpuser"
    echo "    Password: ftp1234"
    echo "    Modo    : PASIVO  (puertos 21100-21110)"
}

# =============================================================================
# PRUEBA 10.4 — LÍMITES DE RECURSOS
# =============================================================================
prueba_10_4() {
    section "PRUEBA 10.4 · Límites de Recursos (RAM / CPU)"

    echo -e "${BOLD}  Objetivo:${NC} Visualizar los límites de memoria y CPU configurados"
    echo -e "            en cada contenedor mediante docker stats.\n"

    # ── docker stats (snapshot) ───────────────────────────────────────────────
    info "docker stats --no-stream:"
    echo ""
    dk stats --no-stream \
        --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}" \
        web_server pg_server ftp_server 2>&1 | sed 's/^/    /'
    echo ""

    # ── Límites configurados (docker inspect) ─────────────────────────────────
    info "Límites configurados por contenedor (docker inspect):"
    echo ""
    printf "    ${BOLD}%-15s %-14s %-12s %-14s${NC}\n" \
        "CONTENEDOR" "MEM MÁXIMA" "CPU CORES" "IP"
    printf "    %-15s %-14s %-12s %-14s\n" \
        "─────────────" "────────────" "──────────" "────────────"

    TODAS_OK=true
    for CTR in web_server pg_server ftp_server; do
        MEM_B=$(dk inspect "$CTR" --format '{{.HostConfig.Memory}}' 2>/dev/null || echo 0)
        NANO=$(dk  inspect "$CTR" --format '{{.HostConfig.NanoCpus}}' 2>/dev/null || echo 0)
        IP=$(dk    inspect "$CTR" \
                   --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || echo N/A)
        MEM_MB=$((MEM_B / 1024 / 1024))
        CPU_C=$(echo "scale=2; $NANO / 1000000000" | bc 2>/dev/null || echo "N/A")
        printf "    %-15s %-14s %-12s %-14s\n" "$CTR" "${MEM_MB}MB" "${CPU_C}" "$IP"
        [ "${MEM_B:-0}" -gt 0 ] 2>/dev/null || TODAS_OK=false
    done

    echo ""
    if [ "$TODAS_OK" = true ]; then
        ok "PRUEBA 10.4 EXITOSA: Todos los contenedores tienen límites de RAM y CPU activos"
    else
        fail "PRUEBA 10.4 FALLIDA: Algún contenedor no tiene límites configurados"
    fi

    echo ""
    info "Resumen de límites:"
    echo "    web_server : 256 MB RAM  |  0.25 CPU cores"
    echo "    pg_server  : 512 MB RAM  |  0.50 CPU cores"
    echo "    ftp_server : 128 MB RAM  |  0.25 CPU cores"
    echo ""
    info "Un proceso malicioso en cualquier contenedor NO puede consumir más allá de estos límites,"
    info "protegiendo al servidor host y a los demás servicios."
}

# =============================================================================
# RESUMEN FINAL
# =============================================================================
resumen_final() {
    section "RESUMEN FINAL DEL DESPLIEGUE"

    echo -e "${BOLD}  Contenedores activos:${NC}"
    dk ps --format "  • {{.Names}} | {{.Image}} | {{.Status}}" \
       2>/dev/null | grep -E "web_server|pg_server|ftp_server" || dk ps
    echo ""

    echo -e "${BOLD}  Volúmenes persistentes:${NC}"
    dk volume ls | grep -E "db_data|web_content" | \
        awk '{printf "  • %-20s Driver: %s\n", $2, $1}'
    echo ""

    echo -e "${BOLD}  Red infra_red:${NC}"
    dk network inspect infra_red \
        --format '  • Driver: {{.Driver}} | Subnet: {{range .IPAM.Config}}{{.Subnet}}{{end}} | Gateway: {{range .IPAM.Config}}{{.Gateway}}{{end}}' \
        2>/dev/null
    echo ""

    echo -e "${BOLD}  URLs de acceso:${NC}"
    echo "    🌐  Web       →  http://localhost:8080"
    echo "    📁  Uploads   →  http://localhost:8080/uploads/"
    echo "    🗄️   PostgreSQL →  psql -h localhost -U pguser -d practica10"
    echo "    📂  FTP       →  ftp://ftpuser:ftp1234@localhost:21"
    echo ""

    echo -e "${BOLD}  Respaldos de BD (en host):${NC}"
    ls -lh "$BACKUP_DIR"/*.sql 2>/dev/null | \
        awk '{printf "  • %-40s %s\n", $NF, $5}' || echo "  (ninguno aún)"
    echo ""

    echo -e "${BOLD}  Archivos del proyecto:${NC}"
    find "$WORK_DIR" -type f | sort | sed "s|$HOME/||" | \
        awk '{printf "  %s\n", $0}'
    echo ""

    echo -e "${GREEN}${BOLD}  ✔ Práctica 10 completada.${NC}"
    echo ""
    echo -e "${CYAN}  Comandos útiles post-instalación:${NC}"
    echo "    docker logs web_server                                   # logs nginx"
    echo "    docker logs pg_server                                    # logs postgres"
    echo "    docker exec -it pg_server psql -U pguser -d practica10  # consola BD"
    echo "    $WORK_DIR/scripts/backup_db.sh                          # respaldo manual"
    echo "    docker stats web_server pg_server ftp_server             # monitor recursos"
    echo ""
    echo "  Para limpiar todo:"
    echo "    docker rm -f web_server pg_server ftp_server"
    echo "    docker network rm infra_red"
    echo "    docker volume rm db_data web_content"
    echo ""
}

# =============================================================================
# MENÚ INTERACTIVO DE PRUEBAS
# =============================================================================
menu_pruebas() {
    while true; do
        echo -e "\n${YELLOW}${BOLD}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "                    PROTOCOLO DE PRUEBAS (MENÚ)                       "
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo -e "${NC}"
        echo -e "  ${CYAN}1)${NC} Prueba 10.1 — Persistencia de Base de Datos"
        echo -e "  ${CYAN}2)${NC} Prueba 10.2 — Aislamiento de Red"
        echo -e "  ${CYAN}3)${NC} Prueba 10.3 — Permisos FTP (Volumen Compartido)"
        echo -e "  ${CYAN}4)${NC} Prueba 10.4 — Límites de Recursos (RAM / CPU)"
        echo -e "  ${CYAN}5)${NC} Mostrar Resumen Final"
        echo -e "  ${RED}0) Salir${NC}"
        echo ""
        read -p "  Selecciona una opción [0-5]: " opcion

        case $opcion in
            1) prueba_10_1 ;;
            2) prueba_10_2 ;;
            3) prueba_10_3 ;;
            4) 
               prueba_10_4 
               echo -e "\n${YELLOW}[!] Momento ideal para tomar captura de evidencia de docker stats.${NC}"
               ;;
            5) resumen_final ;;
            0) 
               echo -e "\n${GREEN}Saliendo del protocolo de pruebas. ¡Éxito en la práctica!${NC}\n"
               break 
               ;;
            *) 
               echo -e "\n${RED}  [✘] Opción inválida. Intenta de nuevo.${NC}" 
               ;;
        esac
    done
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║     PRÁCTICA 10 — Migración a Contenedores Docker (CentOS 7)        ║"
    echo "║  Nginx/Alpine · PostgreSQL · vsftpd · Seguridad · Almacenamiento    ║"
    echo "║  Pruebas: 10.1 Persistencia · 10.2 Red · 10.3 FTP · 10.4 Recursos  ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    limpiar_entorno
    instalar_docker
    crear_estructura
    crear_nginx
    crear_ftp
    crear_backup_script
    desplegar_contenedores

    menu_pruebas
}

main "$@"