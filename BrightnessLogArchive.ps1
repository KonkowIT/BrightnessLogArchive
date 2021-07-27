$host.UI.RawUI.WindowTitle = "BrightnessLogArchive"

# SSH
$username = "sn"
$secpasswd = ConvertTo-SecureString "****" -AsPlainText -Force
$credential = new-object -typename System.Management.Automation.PSCredential -argumentlist $username, $secpasswd
$authenticationKey = ( -join ($($env:USERPROFILE), "\.ssh\ssh-key"))

# API
$requestURL = 'http://api2.arrow.screennetwork.pl/'
$requestHeaders = @{'sntoken' = '****'; 'Content-Type' = 'application/json' }

$serverSN = "10.99.99.10"
$jsonPath = "C:\SN_Scripts\BrightnessLogArchive\sn_data.json"
$script = @"
`$log = 'C:\SCREENNETWORK\LEDBrightness.log'
`$logDir = 'C:\SCREENNETWORK\snled\LedBrights_Logs'

if (Test-Path 'C:\SCREENNETWORK\snled') {
    if (!(Test-Path `$logDir)) { New-Item `$logDir -ItemType Directory -Force }
    
    `$nn = -join('LEDBrightness_', (Get-date -Date (Get-date).AddDays(-3) -Format 'ddMM'), '-',(Get-date -Format 'ddMM'), '.log')
    Move-item -Path `$log -Destination (-join(`$logDir, '\', `$nn)) -Force 
    Write-host (-join('Moving ', `$nn, ' to archive'))

    `$allInDir = gci `$logDir
    
    if (`$allInDir.Count -gt 7) {
        `$allInDir | sort LastWriteTime | select -First (`$allInDir.count - 7) | % { 
            Write-host 'Removing `$_.name'
            Remove-Item `$_.FullName -Force 
        }
    }
}
else {
    Write-Host 'Missing LedBrights'
}
"@

function GetComputersFromAPI {
    [CmdletBinding()]
    param(
        [parameter(ValueFromPipeline)]
        [ValidateNotNull()]
        [String]$networkName,
        [Array]$dontCheck
    )
      
    # Body
    $requestBody = @"
{

"network": [$($networkName)]

}
"@
  
    # Request
    try {
        $request = Invoke-WebRequest -Uri $requestURL -Method POST -Body $requestBody -Headers $requestHeaders -ea Stop
    }
    catch [exception] {
        $Error[0]
        Exit 1
    }
  
    # Creating PS array of sn
    if ($request.StatusCode -eq 200) {
        $requestContent = $request.content | ConvertFrom-Json
    }
    else {
        Write-host ( -join ("Received bad StatusCode for request: ", $request.StatusCode, " - ", $request.StatusDescription)) -ForegroundColor Red
        Exit 1
    }
  
    $snList = @()
    $requestContent | ForEach-Object {
        if ((!($dontCheck -match $_.name)) -and ($_.lok -ne "LOK0014")) {
            $hash = [ordered]@{
                SN           = $_.name;
                IP           = $_.ip;
                Localisation = $_.lok_name.toString().Trim();
            }
  
            $snList = [array]$snList + (New-Object psobject -Property $hash)
        }
    }
  
    return $snList
}

$freshData = @(GetComputersFromAPI -networkName '"LED City", "LED Premium"')

if (Test-Path $jsonPath) { 
    try { [System.Collections.ArrayList]$localData = ConvertFrom-Json (Get-Content $jsonPath -Raw -ea Continue) -ea Continue }
    catch { Write-Host "ERROR: $($_.Exception.message)" }

    foreach ($f in $freshData) {
        $counter = 0
        $ldCount = $localData.Count
        For ($i = 0; $i -lt $ldCount; $i++) {
            
            if ($f.sn -eq $localData[$i].sn) {
                # IP update
                if (($f.ip -ne $localData[$i].ip) -and ($f.ip -ne "NULL") -and ($f.ip -ne "")) {
                    $localData[$i].ip = $f.ip
                }

                # Localisation update
                if ($f.Localisation -ne $localData[$i].Localisation) {
                    $localData[$i].Localisation = $f.Localisation
                }
            }
            else {
                $counter++

                if ($counter -eq $ldCount) {
                    # ADD NEW SN
                    $hash = [ordered]@{
                        SN              = $f.SN;
                        IP              = $f.IP;
                        Localisation    = $f.Localisation;
                    }
              
                    Write-host "Adding $($f.sn) to json"
                    $localData = [array]$localData + (New-Object psobject -Property $hash)
                }
            }
        }
    }

    for ($l = 0; $l -lt $localData.count; $l++) {
        $n = $localData[$l].sn
      
        # REMOVE MISSING SN
        if (!($freshData.sn -contains $n)) {
          Write-host "Removing $n from json"
          $localData.Remove($localData[$l])
        }
    }

    ConvertTo-Json -InputObject $localData | Out-File $jsonPath -Force
}
else {
    ConvertTo-Json -InputObject $freshData | Out-File $jsonPath
}

[System.Collections.ArrayList]$serversArray = ConvertFrom-Json (Get-Content $jsonPath -Raw -ea Stop) -ea Stop

"`n"

# VPN not connected
if (!(Test-Connection -ComputerName $serverSN -Count 3 -Quiet)) {
    do {
        Write-Host "VPN nie polaczony" -ForegroundColor Red
        Start-Sleep -s 60
    }
    until(Test-Connection -ComputerName $serverSN -Count 3 -Quiet)
}
# VPN connected
else {
    foreach ($led in $serversArray) {
        $getSSHSessionId = $null
        $snIP = $led.ip
        $sn = $led.sn
        $snLoc = $led.Localisation
            
        if ($snIP -eq "NULL") {
            Write-host "`nKomputer jest offline: $sn - $snLoc"  -ForegroundColor Red
        }
        else {
            try {
                New-SSHSession -ComputerName $snIP -Credential $credential -KeyFile $authenticationKey -ConnectionTimeout 300 -force -ErrorAction Stop -WarningAction silentlyContinue | out-null
            }
            catch {
                Write-host "`nBlad laczenia z komputerem: $sn - $snLoc"  -ForegroundColor Red
                Write-host $_.Exception.Message
            }

            $getSSHSessionId = (Get-SSHSession | Where-Object { $_.Host -eq $snIP }).SessionId

            if ($null -ne $getSSHSessionId) {
                Write-host "`nPolaczono: $sn - $snLoc" -ForegroundColor Green
                (Invoke-SSHCommand -SessionId $getSSHSessionId -Command "$script").output[0].Trim()
            }

            Write-Host ( -join ("Zamykanie polaczenia SSH: ", (Remove-SSHSession -SessionId $getSSHSessionId)))
        }
    }
}