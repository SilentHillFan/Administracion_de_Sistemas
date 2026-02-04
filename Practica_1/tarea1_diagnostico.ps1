echo "Nombre del equipo:"
$env:COMPUTERNAME

echo "IP:"
(Get-NetIPAddress -InterfaceIndex 4 -AddressFamily IPv4).IPAddress

echo "Espacio en disco (GB):"
(Get-Volume -DriveLetter C).SizeRemaining / 1GB