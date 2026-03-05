# main.ps1
. .\funciones\diagnostico_funciones.ps1
. .\funciones\dhcp_funciones.ps1
. .\funciones\dns_funciones.ps1
. .\funciones\ssh_funciones.ps1
. .\funciones\ftp_funciones.ps1

while ($true) {
    Write-Host ""
    Write-Host "++++++++++++++++++++++++++++++++++"
    Write-Host "   MENU PRINCIPAL - Windows Server"
    Write-Host "++++++++++++++++++++++++++++++++++"
    Write-Host "1) Diagnostico del sistema"
    Write-Host "2) Gestion DHCP"
    Write-Host "3) Gestion DNS"
    Write-Host "4) Gestion SSH"
    Write-Host "5) Gestion FTP"
    Write-Host "6) Salir"
    Write-Host "__________________________________________"
    $OPT = Read-Host "Selecciona una opcion"
    
    switch ($OPT) {
        "1" {
            Mostrar-Diagnostico
        }
        "2" {
            while ($true) {
                Write-Host ""
                Write-Host "++++++++++++++++++++++++++++++++++"
                Write-Host "         SISTEMA DHCP"
                Write-Host "++++++++++++++++++++++++++++++++++"
                Write-Host "1) Verificar instalacion"
                Write-Host "2) Instalar DHCP"
                Write-Host "3) Configurar Ambito"
                Write-Host "4) Monitorear Leases"
                Write-Host "5) Volver"
                Write-Host "__________________________________________"
                $OPT2 = Read-Host "Selecciona una opcion"
                
                switch ($OPT2) {
                    "1" { Verificar-EstadoServicio }
                    "2" { Instalar-DHCP }
                    "3" { Opcion-Configurar }
                    "4" { Opcion-Monitoreo }
                    "5" { break }
                }
                if ($OPT2 -eq "5") { break }
            }
        }
        "3" {
            while ($true) {
                Write-Host ""
                Write-Host "++++++++++++++++++++++++++++++++++"
                Write-Host "      SISTEMA DNS - WINDOWS"
                Write-Host "++++++++++++++++++++++++++++++++++"
                Write-Host "1) Verificar instalacion DNS"
                Write-Host "2) Instalar DNS"
                Write-Host "3) Agregar dominio"
                Write-Host "4) Borrar dominio"
                Write-Host "5) Ver dominios"
                Write-Host "6) Volver"
                Write-Host "__________________________________________"
                $OPT2 = Read-Host "Selecciona una opcion"
                
                switch ($OPT2) {
                    "1" { Opcion-Verificar }
                    "2" { Opcion-Instalar }
                    "3" { Opcion-Agregar }
                    "4" { Opcion-Borrar }
                    "5" { Opcion-Ver }
                    "6" { break }
                }
                if ($OPT2 -eq "6") { break }
            }
        }
        "4" {
            while ($true) {
                Write-Host ""
                Write-Host "++++++++++++++++++++++++++++++++++"
                Write-Host "      SISTEMA SSH - Windows Server"
                Write-Host "++++++++++++++++++++++++++++++++++"
                Write-Host "1) Instalar SSH"
                Write-Host "2) Habilitar SSH"
                Write-Host "3) Configurar Firewall"
                Write-Host "4) Configurar PowerShell como shell default"
                Write-Host "5) Verificar SSH"
                Write-Host "6) Volver"
                Write-Host "__________________________________________"
                $OPT2 = Read-Host "Selecciona una opcion"
                
                switch ($OPT2) {
                    "1" { Instalar-SSH }
                    "2" { Habilitar-SSH }
                    "3" { Configurar-Firewall-SSH }
                    "4" { Configurar-Shell-Default }
                    "5" { Verificar-SSH }
                    "6" { break }
                }
                if ($OPT2 -eq "6") { break }
            }
        }
        "5" {
            while ($true) {
                Write-Host ""
                Write-Host "++++++++++++++++++++++++++++++++++"
                Write-Host "         SISTEMA FTP"
                Write-Host "++++++++++++++++++++++++++++++++++"
                Write-Host "1) Instalar componentes FTP"
                Write-Host "2) Configurar/Reconfigurar FTP"
                Write-Host "3) Ver estado del servicio"
                Write-Host "4) Reiniciar servicio"
                Write-Host "5) Crear usuarios"
                Write-Host "6) Ver usuarios"
                Write-Host "7) Eliminar usuario"
                Write-Host "8) Cambiar grupo de usuario"
                Write-Host "9) Volver"
                Write-Host "__________________________________________"
                $OPT2 = Read-Host "Selecciona una opcion"
                
                switch ($OPT2) {
                    "1" { Opcion-Instalar-FTP }
                    "2" { Opcion-Configurar-FTP }
                    "3" { Opcion-Estado-FTP }
                    "4" { Opcion-Reiniciar-FTP }
                    "5" { Opcion-Crear-Usuarios }
                    "6" { Opcion-Ver-Usuarios }
                    "7" { Opcion-Eliminar-Usuario }
                    "8" { Opcion-Cambiar-Grupo }
                    "9" { break }
                    default { Write-Host "Opcion no valida" }
                }
                if ($OPT2 -eq "9") { break }
            }
        }
        "6" { 
            Write-Host "Saliendo del programa..."
            exit 
        }
        default { 
            Write-Host "Opcion invalida. Intenta de nuevo."
            Read-Host "Presiona Enter para continuar"
        }
    }
}