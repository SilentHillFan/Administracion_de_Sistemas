#!/bin/bash
# ==============================================================
# PRACTICA 11 - Orquestacion de Infraestructura Docker
# CentOS 7 | Ejecutar como: sudo bash practica11.sh
# ==============================================================

WORKDIR="/opt/practica11"

VERDE='\033[0;32m'
ROJO='\033[0;31m'
AMARILLO='\033[1;33m'
CYAN='\033[0;36m'
BLANCO='\033[1;37m'
RESET='\033[0m'

ok()        { echo -e "  ${VERDE}[OK]${RESET}   $1"; }
fail()      { echo -e "  ${ROJO}[FAIL]${RESET} $1"; }
info()      { echo -e "  ${AMARILLO}[INFO]${RESET} $1"; }
titulo()    { echo ""; echo -e "${CYAN}======================================================${RESET}";
              echo -e "${BLANCO}  $1${RESET}";
              echo -e "${CYAN}======================================================${RESET}"; echo ""; }
separador() { echo -e "${CYAN}------------------------------------------------------${RESET}"; }

cargar_env() {
    if [ -f "$WORKDIR/.env" ]; then
        export $(grep -v '^#' "$WORKDIR/.env" | xargs)
    else
        echo -e "${ROJO}  ERROR: No se encontro $WORKDIR/.env${RESET}"
        echo "  Ejecuta primero la opcion 1 (Instalar infraestructura)."
        return 1
    fi
}

# ==============================================================
# INSTALACION COMPLETA
# ==============================================================
instalar() {
    titulo "INSTALANDO INFRAESTRUCTURA COMPLETA"

    info "Verificando Docker..."
    if ! command -v docker &>/dev/null; then
        info "Instalando Docker..."
        yum install -y yum-utils device-mapper-persistent-data lvm2
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        yum install -y docker-ce docker-ce-cli containerd.io
        systemctl start docker
        systemctl enable docker
        ok "Docker instalado."
    else
        ok "Docker ya instalado: $(docker --version)"
    fi

    info "Verificando Docker Compose..."
    if ! command -v docker-compose &>/dev/null; then
        info "Instalando Docker Compose 1.29.2..."
        curl -sL \
          "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" \
          -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
        ok "Docker Compose instalado."
    else
        ok "Docker Compose ya instalado: $(docker-compose --version)"
    fi

    info "Creando estructura de directorios..."
    mkdir -p "$WORKDIR/nginx" "$WORKDIR/webapp"
    cd "$WORKDIR"

    cat > "$WORKDIR/.env" <<'EOF'
NGINX_PORT=80
POSTGRES_DB=practica11_db
POSTGRES_USER=admin_practica
POSTGRES_PASSWORD=MiPassword2024Segura!
PGADMIN_EMAIL=admin@practica11.local
PGADMIN_PASSWORD=AdminPgAdmin2024!
EOF
    ok ".env creado"

    cat > "$WORKDIR/nginx/nginx.conf" <<'EOF'
events { worker_connections 1024; }
http {
    server_tokens off;
    upstream app_backend { server webapp:80; }
    server {
        listen 80;
        server_name _;
        location / {
            proxy_pass         http://app_backend;
            proxy_set_header   Host              $host;
            proxy_set_header   X-Real-IP         $remote_addr;
            proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_hide_header  Server;
            proxy_hide_header  X-Powered-By;
        }
    }
}
EOF
    ok "nginx/nginx.conf creado"

    cat > "$WORKDIR/webapp/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="es">
<head><meta charset="UTF-8"><title>Practica 11 - Servidor Interno</title>
<style>
  body { font-family:monospace; background:#1a1a2e; color:#00ff88;
         display:flex; justify-content:center; align-items:center;
         height:100vh; margin:0; flex-direction:column; }
  .box { border:1px solid #00ff88; padding:30px; text-align:center; }
  h1   { color:#00ccff; }
</style></head>
<body><div class="box">
  <h1>Servidor de Aplicaciones Interno</h1>
  <p>Este contenedor NO tiene puertos expuestos al host.</p>
  <p>Accesible SOLO a traves del balanceador <strong>nginx</strong>.</p>
  <hr style="border-color:#00ff88">
  <p>Practica 11 - Orquestacion de Infraestructura</p>
</div></body></html>
EOF
    ok "webapp/index.html creado"

    cat > "$WORKDIR/docker-compose.yml" <<'EOF'
version: "3.3"
services:

  nginx:
    image: nginx:1.24-alpine
    container_name: practica11_nginx
    restart: always
    ports:
      - "${NGINX_PORT}:80"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
    networks:
      - red_publica
    depends_on:
      - webapp
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost/"]
      interval: 15s
      timeout: 5s
      retries: 3

  webapp:
    image: nginx:1.24-alpine
    container_name: practica11_webapp
    restart: always
    volumes:
      - ./webapp/index.html:/usr/share/nginx/html/index.html:ro
    networks:
      - red_publica
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost/"]
      interval: 15s
      timeout: 5s
      retries: 3

  postgres:
    image: postgres:13-alpine
    container_name: practica11_postgres
    restart: always
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - pgdata:/var/lib/postgresql/data
    networks:
      - red_datos
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 20s

  pgadmin:
    image: dpage/pgadmin4:7.8
    container_name: practica11_pgadmin
    restart: always
    environment:
      PGADMIN_DEFAULT_EMAIL: ${PGADMIN_EMAIL}
      PGADMIN_DEFAULT_PASSWORD: ${PGADMIN_PASSWORD}
      PGADMIN_LISTEN_PORT: 80
    volumes:
      - pgadmin_data:/var/lib/pgadmin
    networks:
      - red_datos
    depends_on:
      postgres:
        condition: service_healthy

networks:
  red_publica:
    driver: bridge
  red_datos:
    driver: bridge

volumes:
  pgdata:
    driver: local
  pgadmin_data:
    driver: local
EOF
    ok "docker-compose.yml creado"

    info "Configurando firewall..."
    if ! systemctl is-active --quiet firewalld; then
        systemctl start firewalld
        systemctl enable firewalld
    fi
    firewall-cmd --permanent --remove-port=5432/tcp 2>/dev/null || true
    firewall-cmd --permanent --remove-port=8080/tcp 2>/dev/null || true
    firewall-cmd --permanent --add-service=ssh  2>/dev/null || true
    firewall-cmd --permanent --add-service=http 2>/dev/null || true
    firewall-cmd --reload
    ok "Firewall configurado."

    info "Levantando el stack..."
    export $(grep -v '^#' "$WORKDIR/.env" | xargs)
    docker-compose up -d

    info "Esperando healthchecks (25 segundos)..."
    sleep 25

    titulo "STACK LISTO"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo ""
    ok "Instalacion completada."
}

# ==============================================================
# PRUEBA 11.2 — Resolucion Interna DNS
# Accion: docker exec en nginx, ping al nombre del servicio DB
# ==============================================================
prueba_11_2() {
    titulo "PRUEBA 11.2 — Validacion de Resolucion Interna DNS"
    cargar_env || return

    echo -e "${BLANCO}  Accion:${RESET} docker exec dentro del contenedor pgadmin,"
    echo    "  ping al nombre del servicio postgres (ambos en red_datos)."
    echo ""
    separador

    echo ""
    echo -e "${BLANCO}  Instalando ping en el contenedor pgadmin (imagen alpine)...${RESET}"
    docker exec practica11_pgadmin apk add --no-cache iputils 2>/dev/null || true
    echo ""

    separador
    echo ""
    echo -e "${BLANCO}  Comando ejecutado:${RESET}"
    echo    "  docker exec -u root practica11_pgadmin ping -c 4 postgres"
    echo ""
    separador
    echo ""

    docker exec -u root practica11_pgadmin ping -c 4 postgres
    RESULTADO_PING=$?

    echo ""
    separador
    echo ""
    if [ $RESULTADO_PING -eq 0 ]; then
        ok "DNS interno resuelto correctamente. postgres es alcanzable por nombre de servicio."
    else
        fail "El ping fallo. Verifica que pgadmin y postgres esten en red_datos."
    fi
    echo ""
}

# ==============================================================
# PRUEBA 11.4 — Persistencia y Healthcheck
# Accion: docker-compose down, borrar contenedores, iniciar de nuevo
# ==============================================================
prueba_11_4() {
    titulo "PRUEBA 11.4 — Validacion de Persistencia y Buen Funcionamiento"
    cargar_env || return

    echo -e "${BLANCO}  Accion:${RESET} Detener el stack, borrar contenedores,"
    echo    "  iniciar de nuevo y verificar datos y orden de inicio."
    echo ""
    separador

    # --- Insertar dato antes de bajar ---
    echo ""
    echo -e "${BLANCO}  [1/5] Insertando dato de prueba en PostgreSQL...${RESET}"
    echo ""
    docker exec practica11_postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
        -c "CREATE TABLE IF NOT EXISTS prueba_persistencia (
              id SERIAL PRIMARY KEY,
              mensaje TEXT,
              fecha TIMESTAMP DEFAULT NOW()
            );"
    docker exec practica11_postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
        -c "INSERT INTO prueba_persistencia (mensaje)
            VALUES ('Dato creado antes del reinicio - $(date)');"
    echo ""
    echo    "  Datos actuales en la tabla:"
    docker exec practica11_postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
        -c "SELECT * FROM prueba_persistencia;"

    separador

    # --- Bajar el stack ---
    echo ""
    echo -e "${BLANCO}  [2/5] Ejecutando docker-compose down...${RESET}"
    echo ""
    cd "$WORKDIR"
    docker-compose down
    echo ""
    echo    "  Contenedores tras docker-compose down:"
    docker ps -a --format "table {{.Names}}\t{{.Status}}" 2>/dev/null | grep practica11 \
        || echo "  (ninguno — todos eliminados)"

    separador

    # --- Levantar de nuevo ---
    echo ""
    echo -e "${BLANCO}  [3/5] Ejecutando docker-compose up -d...${RESET}"
    echo ""
    docker-compose up -d

    separador

    # --- Observar orden de inicio con healthcheck ---
    echo ""
    echo -e "${BLANCO}  [4/5] Monitoreando orden de inicio (postgres debe ser healthy${RESET}"
    echo -e "${BLANCO}  antes de que pgadmin suba)...${RESET}"
    echo ""
    printf "  %-30s %-15s %-15s\n" "TIEMPO" "POSTGRES" "PGADMIN"
    separador

    INTENTOS=0
    HEALTHCHECK_OK=0
    while [ $INTENTOS -lt 15 ]; do
        HEALTH=$(docker inspect practica11_postgres \
            --format='{{.State.Health.Status}}' 2>/dev/null || echo "starting")
        PGADMIN_ST=$(docker inspect practica11_pgadmin \
            --format='{{.State.Status}}' 2>/dev/null || echo "waiting")
        printf "  %-30s %-15s %-15s\n" "+$((INTENTOS * 5))s" "$HEALTH" "$PGADMIN_ST"
        if [ "$HEALTH" = "healthy" ] && [ "$PGADMIN_ST" = "running" ]; then
            HEALTHCHECK_OK=1
            break
        fi
        sleep 5
        INTENTOS=$((INTENTOS + 1))
    done

    separador
    echo ""
    if [ $HEALTHCHECK_OK -eq 1 ]; then
        ok "postgres alcanzo estado healthy y pgadmin inicio correctamente."
    else
        fail "Timeout: postgres no alcanzo estado healthy en 75s o pgadmin no subio."
    fi

    separador

    # --- Estado final ---
    echo ""
    echo -e "${BLANCO}  [5/5] Estado final y verificacion de datos persistentes${RESET}"
    echo ""
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo ""
    echo    "  Consultando datos en PostgreSQL tras el reinicio:"
    echo ""
    docker exec practica11_postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
        -c "SELECT * FROM prueba_persistencia;"

    separador
    echo ""
    RESULTADO=$(docker exec practica11_postgres psql \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
        -c "SELECT mensaje FROM prueba_persistencia ORDER BY id DESC LIMIT 1;" \
        -t 2>/dev/null | xargs)

    if echo "$RESULTADO" | grep -q "Dato creado antes del reinicio"; then
        ok "Datos intactos tras el reinicio. Volumen funcionando correctamente."
    else
        fail "No se encontro el dato previo al reinicio."
    fi

    echo ""
    echo -e "${BLANCO}  Resultado esperado segun la practica:${RESET}"
    echo    "  pgadmin espera a que postgres este healthy antes de iniciar."
    echo    "  Los datos previos estan intactos gracias al volumen nombrado."
    echo ""
}

# ==============================================================
# VER ESTADO
# ==============================================================
ver_estado() {
    titulo "ESTADO ACTUAL DEL STACK"
    echo "  Contenedores:"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null \
        || echo "  No hay contenedores corriendo."
    echo ""
    echo "  Redes:"
    docker network ls | grep practica11 || echo "  (sin redes de practica11)"
    echo ""
    echo "  Volumenes:"
    docker volume ls | grep practica11 || echo "  (sin volumenes de practica11)"
    echo ""
}


# ==============================================================
# PRUEBA 11.3 — Tunnel SSH
# ==============================================================
tunel_11_3() {
    titulo "PRUEBA 11.3 — Comando de Tunel SSH"
    cargar_env || return

    IP_PGADMIN=$(docker inspect practica11_pgadmin \
        --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)

    if [ -z "$IP_PGADMIN" ]; then
        fail "No se pudo obtener la IP de practica11_pgadmin. Verifica que el contenedor este corriendo."
        return
    fi

    ok "IP actual de pgadmin: ${BLANCO}${IP_PGADMIN}${RESET}"
    echo ""
    echo -e "${BLANCO}  Ejecuta este comando desde tu maquina Windows:${RESET}"
    echo ""
    echo -e "  ${AMARILLO}ssh -L 8080:${IP_PGADMIN}:80 $(whoami)@$(hostname -I | awk '{print $1}')${RESET}"
    echo ""
    echo    "  Luego abre en tu navegador: http://localhost:8080"
    echo ""
    echo -e "${BLANCO}  Credenciales pgAdmin:${RESET}"
    echo    "  Email   : ${PGADMIN_EMAIL}"
    echo    "  Password: ${PGADMIN_PASSWORD}"
    echo ""
}

# ==============================================================
# BORRAR TODO
# ==============================================================
borrar_todo() {
    titulo "BORRAR INFRAESTRUCTURA COMPLETA"
    echo -e "  ${ROJO}ADVERTENCIA: Elimina contenedores Y volumenes (datos).${RESET}"
    echo ""
    read -rp "  Escribe 'si' para confirmar: " CONFIRMAR
    if [ "$CONFIRMAR" = "si" ]; then
        cd "$WORKDIR" 2>/dev/null || true
        docker-compose down -v 2>/dev/null || true
        ok "Stack y volumenes eliminados."
    else
        info "Cancelado."
    fi
    echo ""
}

# ==============================================================
# MENU
# ==============================================================
menu() {
    while true; do
        clear
        echo -e "${CYAN}"
        echo "  ╔══════════════════════════════════════════════════╗"
        echo "  ║      PRACTICA 11 — Infraestructura Docker        ║"
        echo "  ╠══════════════════════════════════════════════════╣"
        echo -e "  ║${RESET}  1)  Instalar infraestructura completa           ${CYAN}║"
        echo -e "  ║${RESET}  ─────────────────────────────────────────────   ${CYAN}║"
        echo -e "  ║${RESET}  2)  Prueba 11.2 — Resolucion DNS Interna        ${CYAN}║"
        echo -e "  ║${RESET}  3)  Prueba 11.3 — Comando Tunel SSH             ${CYAN}║"
        echo -e "  ║${RESET}  4)  Prueba 11.4 — Persistencia y Healthcheck    ${CYAN}║"
        echo -e "  ║${RESET}  ─────────────────────────────────────────────   ${CYAN}║"
        echo -e "  ║${RESET}  5)  Ver estado del stack                        ${CYAN}║"
        echo -e "  ║${RESET}  6)  Borrar todo (contenedores + volumenes)      ${CYAN}║"
        echo -e "  ║${RESET}  0)  Salir                                       ${CYAN}║"
        echo "  ╚══════════════════════════════════════════════════╝"
        echo -e "${RESET}"
        read -rp "  Selecciona una opcion: " OPT
        echo ""
        case $OPT in
            1) instalar      ;;
            2) prueba_11_2   ;;
            3) tunel_11_3    ;;
            4) prueba_11_4   ;;
            5) ver_estado    ;;
            6) borrar_todo   ;;
            0) echo "  Saliendo..."; echo ""; exit 0 ;;
            *) echo -e "  ${ROJO}Opcion invalida.${RESET}" ;;
        esac
        echo ""
        read -rp "  Presiona ENTER para volver al menu..." _
    done
}

menu
