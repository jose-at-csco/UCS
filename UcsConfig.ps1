<#

UcsConfig.ps1 Version=1.0
Created by Tim Cerling
tcerling@cisco.com

  Execution string:  .\UcsConfig.ps1 -path <path> -validateOnly -toConsole
   <path> - location of input file UcsConfig.xml
   -validateOnly - only validate contents of UcsConfig.xml.  Does not update UCS
   -toConsole - output log file to console instead of log file

This script reads the contents of a configuration file (UcsConfig.XML) that defines the
various pools, policies, templates, and profiles necessary to perform an initial 
deployment of a complete UCS system.  It configures the Fabric Interconnect cabling as well
as defining all the components necessary to create service profiles.

All parameters that would normally be entered into the UCSM console are captured into the
UcsConfig.XML file.  Since that requires editing by an individual, this script is divided
into two major components
  1. Validation - the contents of UcsConfig.xml are validated for proper values and formats.
     It is possible to ignore inputs in any field if it is not desired to update that field.
  2. Update - Upon successful completion of validation, the values can be applied to the
     Fabric Interconnects to configure and deploy the system.  The -ModifyPresent parameter
     is used on all update commands, allowing this script to be run against an existing
     system to update it.

One of the goals of this script was to make it easy to understand by someone who is not
very familiar with PowerTool/PowerShell, as a goal is to provide this to consultants to be 
able to use this to quickly deploy an environment.  Therefore, it is important to keep it
simple to understand and easy to modify, avoiding compact 'PowerShell-isms' that are more
difficult to determine function.

Because of the length of some of the PowerTool commands, the line continuation character (`)
has been used.  However, when it is used, the subsequent portion of the line is indented
to make it more obvious to the reader.  Use of the continuation character allows for the
complete command to be contained within the viewing area of the PowerShell ISE with no
need to scroll back and forth to see all the required parameters.

/#>

Param
(
    [Parameter(Mandatory=$false,Position=0)]
    [String]$path = (Get-Location),

    [Parameter(Mandatory=$false)]
    [Switch]$validateOnly = $false,

    [Parameter(Mandatory=$false)]
    [Switch]$toConsole = $false
)

################################################################################
#
# Function Definitions
#
# ------------------------------------------------------------------------------

# Function to write log information to either log file or console
# Displays the line number of where the error occurred to ease in debugging the
#   inputs
Function Write-Log ($content, $type)
{
    $n = (get-pscallstack).Length - 2
    $lineNum = ((get-pscallstack)[$n].Location -split " line ")[1]

    switch ($type)
    {
        Normal
        {
            If ($ToConsole)
            {
                Write-Host -ForegroundColor Green "$lineNum $(Get-Date -Format "HH:mm:ss") - $content"
            }
            Else
            {
                Add-Content -Path $logFilePath -Value "$lineNum - $(Get-Date -Format g): $content"
            }
        }
        Error
        {
            If ($ToConsole)
            {
                Write-Host -ForegroundColor Red -BackgroundColor Black "ERROR at line $lineNum `n$content"
            }
            Else
            {
                Add-Content -Path $logFilePath -Value "ERROR at line $lineNum - $(Get-Date -Format g): $content"
            }
        }
    }
}

################################################################################
#
# Regular expressions used for validation
#
# ------------------------------------------------------------------------------

$validIPAddress = @"
^([1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])(\.([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])){3}$
"@

$validHex = @"
^([A-Fa-f0-9]{2})
"@

$validMAC = @"
^([0-9A-Fa-f]){2}(\:([0-9A-Fa-f]){2}){5}$
"@

$validWWN = @"
^([0-9A-Fa-f]){2}(\:([0-9A-Fa-f]){2}){7}$
"@

$validUUID = @"
^([A-Fa-f0-9]){4}(\-([A-Fa-f0-9]){12})
"@

$validSuffix = @"
^([A-Fa-f0-9:]{5})
"@

$validNumList = @"
^([0-9,-])
"@

$validDigit = @"
^([0-9])
"@

################################################################################
#
# Definition of constants
#
# ------------------------------------------------------------------------------

$startTime = Get-Date
$originalPath = Get-Location
$errTag = $False
$logFile = "UcsConfig.log"

$chassisDiscoveryOptions = @()          #Table of chassis discovery options
$chassisDiscoveryOptions +=, ("1-link")
$chassisDiscoveryOptions +=, ("2-link")
$chassisDiscoveryOptions +=, ("4-link")
$chassisDiscoveryOptions +=, ("8-link")
$chassisDiscoveryOptions +=, ("platform-max")

$diskPolicyOptions = @()                #Table of local disk policy options
$diskPolicyOptions +=, ('any-configuration')
$diskPolicyOptions +=, ('no-local-storage')
$diskPolicyOptions +=, ('no-raid')
$diskPolicyOptions +=, ('raid-striped')
$diskPolicyOptions +=, ('raid-mirrored')
$diskPolicyOptions +=, ('raid-mirrored-striped')
$diskPolicyOptions +=, ('raid-striped-parity')
$diskPolicyOptions +=, ('raid-striped-dual-parity')

$fiPortRoles = @()                      #Table of server roles for FI port configuration
$fiPortRoles +=, ('server')
$fiPortRoles +=, ('uplink')
$fiPortRoles +=, ('appliance')
$fiPortRoles +=, ('fcoe')
$fiPortRoles +=, ('')

$poolType = @()                         #Table of types of pools
$poolType +=, ('MAC')
$poolType +=, ('UUID')
$poolType +=, ('WWNN')
$poolType +=, ('WWPN')

$objectTable = @()                       #Table of found objects in ucsConfig.xml file
$objectTable +=, ('TimeZone', 0)
$objectTable +=, ('NTP', 0)
$objectTable +=, ('MgmtIP', 0)
$objectTable +=, ('CallHome', 0)
$objectTable +=, ('ChassisDiscovery', 0)
$objectTable +=, ('SubOrg', 0)
$objectTable +=, ('SANWWPN.SPAprimary', 0)
$objectTable +=, ('SANWWPN.SPAsecondary', 0)
$objectTable +=, ('SANWWPN.SPBprimary', 0)
$objectTable +=, ('SANWWPN.SPBsecondary', 0)
$objectTable +=, ('QoS', 0)
$objectTable +=, ('PowerPolicy', 0)
$objectTable +=, ('ScrubPolicy', 0)
$objectTable +=, ('MaintenancePolicy', 0)
$objectTable +=, ('DiskPolicy', 0)
$objectTable +=, ('BIOSPolicy', 0)
$objectTable +=, ('PlacementPolicy', 0)
$objectTable +=, ('FI', 0)
$objectTable +=, ('FCslot1', 0)
$objectTable +=, ('FCslot2', 0)
$objectTable +=, ('PC', 0)
$objectTable +=, ('Pools', 0)
$objectTable +=, ('VLANs', 0)
$objectTable +=, ('VNICtemplate', 0)
$objectTable +=, ('VHBAtemplate', 0)
$objectTable +=, ('BootPolicy', 0)
$objectTable +=, ('SPTemplate', 0)
$objectTable +=, ('ServiceProfile', 0)


################################################################################
################################################################################
################################################################################
#
# Start of Code
#
# ------------------------------------------------------------------------------

# Change to path entered on command line
If (Test-Path $path -PathType Container) 
{
    Set-Location $path
}
    Else
    {
        $errTag = $True
        Write-Host "Invalid path" -ForegroundColor Red
    }

# Read input file
If (Test-Path "$path\ucsconfig.xml")
{
    try {$ucsConfig = [XML] (Get-Content "$path\UcsConfig.xml") } 
    catch {$errTag = $True; Write-Host "Invalid UcsConfig.xml" -ForegroundColor Red}
}
    Else
    {
        $errTag = $True
        Write-Host "Missing UcsConfig.xml" -ForegroundColor Red
    }

# Create a log file in the same directory from which the script is running
If (!$errTag)
{
    If (!$toConsole)
    {
        $localPath = Split-Path (Resolve-Path $MyInvocation.MyCommand.Path)
        $logFilePath = Join-Path $localPath $logFile
        If (Test-Path($logFilePath)) 
        {
            Write-Host "Deleting existing log file"
            Remove-Item $logFilePath
        }
        Write-Host "Creating new log file $logfilePath"
        $trash = New-Item -Path $localPath -Name $logFile -ItemType "file"
    }
}

# Import required modules
if ((Get-Module |where {$_.Name -ilike "CiscoUcsPS"}).Name -ine "CiscoUcsPS")
     {
     Write-Host "Loading Module: Cisco UCS PowerTool Module"
     Import-Module CiscoUcsPs
     }

$trash = set-ucspowertoolconfiguration -supportmultipledefaultucs $false

# Test whether to continue processing
If ($errTag)
{
    Set-Location $originalPath
    $endTime = Get-Date
    $elapsedTime = New-TimeSpan $startTime $endTime
    Write-Host -ForegroundColor Yellow -BackgroundColor Black "`n`n-----------------------------------------------------------`n"
    Write-Log "Elapsed time: $($elapsedTime.Hours):$($elapsedTime.Minutes):$($elapsedTime.Seconds)"
    Write-Log "End of processing.`n"
    Exit
}

################################################################################
################################################################################
# ------------------------------------------------------------------------------
#
# Start validating the UcsConfig.xml file
#
# ------------------------------------------------------------------------------
################################################################################

$error.Clear()
Write-Log "Validating contents of $path\UcsConfig.xml"

##########
# Validate UCSM IP address - must be able to communicate with UCSM
#  Input sample: <UCSMIP>10.29.130.100 </UCSMIP>

$tmp1 = $ucsConfig.VSPEX.UCSMIP.trim()
$tmp = Test-Connection $tmp1 -Count 1 -Quiet
If ($tmp)
{
    Write-Log "UCSM IP address $tmp1 is reachable." "Normal"
}
    Else
    {
        Write-Log "UCSM IP address $tmp1 is unreachable." "Error"
        $errTag = $True
    }

##########
# Validate Management IP settings - ensure proper format of IP addresses
#  Input sample:
#   <MgmtIP>
#    <Pool Name='MgmtIP' Descr='Service Profile management IPs' >
#      <Order>sequential </Order>
#      <Start>10.5.177.200 </Start>
#      <End>10.5.177.249 </End>
#      <Gateway>10.5.177.1 </Gateway>
#      <PrimaryDNS>0.0.0.0 </PrimaryDNS>
#      <SecondaryDNS>0.0.0.0 </SecondaryDNS>
#    </Pool>
#  </MgmtIP>

$ucsConfig.VSPEX.MgmtIP | ForEach-Object {$_.Pool} | ForEach-Object {
    $tmp1 = $_
    If ($tmp1 -ne $null)
    {
        For ($i=0; $i -lt $objectTable.length; $i++)
        {
            $obj = $objectTable[$i]
            If ($obj[0] -eq 'MgmtIP') {$obj[1] = 1; Break}
        }
        $tmp2 = $_.Name.trim()
        $tmp1 | ForEach-Object {
            $tmp = $False
            $tmp3 = $_.Order.trim()
            $tmp4 = $_.Start.trim()
            $tmp5 = $_.End.trim()
            $tmp6 = $_.Gateway.trim()
            $tmp7 = $_.PrimaryDNS.trim()
            $tmp8 = $_.SecondaryDNS.trim()
            If (!($tmp3 -eq 'default' -or $tmp3 -eq 'sequential'))
            {
               Write-Log "Invalid management pool assignment order - Name=$tmp2 Start=$tmp3" "Error"
               $tmp = $True
            }
            If (!($tmp4 -match $validIPaddress))
            {
                Write-Log "Invalid management pool start IP address - Name=$tmp2 Start=$tmp4" "Error"
               $tmp = $True
            }
            If (!($tmp5 -match $validIPaddress))
            {
                Write-Log "Invalid management pool end IP address - Name=$tmp2 Start=$tmp5" "Error"
                $tmp = $True
            }
            If ($tmp4 -ge $tmp5)
            {
                Write-Log "Management pool end IP address must be greater than start - Name=$tmp2 Start=$tmp4 End=$tmp5" "Error"
                $tmp = $True
            }
            If (!($tmp6 -match $validIPaddress))
            {
                Write-Log "Invalid management pool gateway IP address - Name=$tmp2 Start=$tmp6" "Error"
                $tmp = $True
            }
            If ($tmp7 -ne '0.0.0.0')
            {
                If (!($tmp7 -match $validIPaddress))
                {
                    Write-Log "Invalid management pool primary DNS IP address - Name=$tmp2 Primary=$tmp7" "Error"
                    $tmp = $True
                }
            }
            If ($tmp8 -ne '0.0.0.0')
            {
                If (!($tmp8 -match $validIPaddress))
                {
                    Write-Log "Invalid management pool secondary DNS IP address - Name=$tmp2 Secondary=$tmp8" "Error"
                    $tmp = $True
                }
            }
            If (!$tmp)
            {
                Write-Log "Management IP pool - Name=$tmp2 Order=$tmp3 Start=$tmp4 End=$tmp5 G/W=$tmp6 Primary=$tmp7 Secondary=$tmp8" "Normal"
            }
            Else
            {
                Write-Log "Invalid management IP pool - Name=$tmp2 Order=$tmp3 Start=$tmp4 End=$tmp5 G/W=$tmp6 Primary=$tmp7 Secondary=$tmp8" "Error"
                $errTag = $True
            }
        }
    }
}

##########
# Validate Chassis discovery setting - ensure valid character strings for setting
#  Input sample:  <ChassisDiscovery>2-link </ChassisDiscovery>

$tmp1 = $ucsConfig.VSPEX.ChassisDiscovery
If ($tmp1 -ne $null)
{
    For ($i=0; $i -lt $objectTable.length; $i++)
    {
        $obj = $objectTable[$i]
        If ($obj[0] -eq 'ChassisDiscovery') {$obj[1] = 1; Break}
    }
    $tmp1 = $tmp1.trim()
    For ($i=0; $i -lt $chassisDiscoveryOptions.length; $i++)
    {
        If ($tmp1 -eq $chassisDiscoveryOptions[$i])
        {
            Write-Log "Valid chassis discovery - $tmp1" "Normal"
            Break
        }
    }
    If ($i -eq $chassisDiscoveryOptions.length)
    {
        Write-Log "Invalid chassis discovery option - $tmp1" "Error"
        $errTag = $True
    }
}

##########
# Validate SAN WWPN values - ensure proper format
# Input sample: 
#  <SANWWPN>
#    <SPAprimary>50:06:01:65:08:60:06:A1 </SPAprimary>
#    <SPAsecondary>50:06:01:64:08:60:06:A1 </SPAsecondary>
#    <SPBprimary>50:06:01:6D:08:60:06:A1 </SPBprimary>
#    <SPBsecondary>50:06:01:6C:08:60:06:A1 </SPBsecondary>
#  </SANWWPN>

$tmp1 = $ucsConfig.VSPEX.SANWWPN.SPAprimary
If ($tmp1 -ne $null)
{
    For ($i=0; $i -lt $objectTable.length; $i++)
    {
        $obj = $objectTable[$i]
        If ($obj[0] -eq 'SANWWPN.SPAprimary') {$obj[1] = 1; Break}
    }
    $tmp1 = $tmp1.trim()
    If ($tmp1 -match $validWWN)
    {
        Write-Log "Valid Port-A Primary WWPN   - $tmp1" "Normal"
        $sanSPAprimary = $tmp1
    }
    Else
    {
        Write-Log "Invalid Port-A Primary WWPN   - $tmp1" "Error"
        $errTag = $True
    }
}

$tmp1 = $ucsConfig.VSPEX.SANWWPN.SPAsecondary
If ($tmp1 -ne $null)
{
    For ($i=0; $i -lt $objectTable.length; $i++)
    {
        $obj = $objectTable[$i]
        If ($obj[0] -eq 'SANWWPN.SPAsecondary') {$obj[1] = 1; Break}
    }
    $tmp1 = $tmp1.trim()
    If ($tmp1 -match $validWWN)
    {
        Write-Log "Valid Port-A Secondary WWPN - $tmp1" "Normal"
        $sanSPAsecondary = $tmp1
    }
    Else
    {
        Write-Log "Invalid Port-A Secondary WWPN - $tmp1" "Error"
        $errTag = $True
    }
}

$tmp1 = $ucsConfig.VSPEX.SANWWPN.SPBprimary
If ($tmp1 -ne $null)
{
    For ($i=0; $i -lt $objectTable.length; $i++)
    {
        $obj = $objectTable[$i]
        If ($obj[0] -eq 'SANWWPN.SPBprimary') {$obj[1] = 1; Break}
    }
    $tmp1 = $tmp1.trim()
    If ($tmp1 -match $validWWN)
    {
        Write-Log "Valid Port-B Primary WWPN   - $tmp1" "Normal"
        $sanSPBprimary = $tmp1
    }
    Else
    {
        Write-Log "Invalid Port-B Primary WWPN   - $tmp1" "Error"
        $errTag = $True
    }
}

$tmp1 = $ucsConfig.VSPEX.SANWWPN.SPBsecondary
If ($tmp1 -ne $null)
{
    For ($i=0; $i -lt $objectTable.length; $i++)
    {
        $obj = $objectTable[$i]
        If ($obj[0] -eq 'SANWWPN.SPBsecondary') {$obj[1] = 1; Break}
    }
    $tmp1 = $tmp1.trim()
    If ($tmp1 -match $validWWN)
    {
        Write-Log "Valid Port-B Secondary WWPN - $tmp1" "Normal"
        $sanSPBsecondary = $tmp1
    }
    Else
    {
        Write-Log "Invalid Port-B Secondary WWPN - $tmp1" "Error"
        $errTag = $True
    }
}

##########
# Validate Power Control Policies - ensure proper character strings
# Input sample: 
#  <PowerPolicy>
#    <Var Name='default' Priority='no-cap' />
#    <Var Name='Cap_1' Priority='1' /> 
#    <Var Name='Cap_2' Priority='2' /> 
#    <Var Name='NoCap' Priority='no-cap' /> 
#  </PowerPolicy>

$tmp1 = $ucsConfig.VSPEX.PowerPolicy
If ($tmp1 -ne $null)
{
    For ($i=0; $i -lt $objectTable.length; $i++)
    {
        $obj = $objectTable[$i]
        If ($obj[0] -eq 'PowerPolicy') {$obj[1] = 1; Break}
    }
    $ucsConfig.VSPEX.PowerPolicy | ForEach-Object {$_.Var} | ForEach-Object {
        $tmp1 = $_.Name.trim()
        $tmp2 = $_.Priority.trim()
        $tmp3 = $_.Priority.trim()
        If ($tmp3 -eq 'no-cap')
        {
           Write-Log "Valid Power Control Policy on entry - Name=$tmp1 Priority=$tmp3" "Normal"
        }
        Else
        {
            If ([int]$tmp2 -ge 1 -and [int]$tmp2 -le 10)
            {
                Write-Log "Valid Power Control Policy on entry - Name=$tmp1 Priority=$tmp2" "Normal"
            }
            Else
            { 
                Write-Log "Invalid Power Control Policy on entry - Name=$tmp1 Priority=$tmp3" "Error"
                $errTag = $True
            }
        }
    }
}

##########
# Validate Scrub Policies
# Input sample:
#  <ScrubPolicy>
#    <Var Name='NoScrub' Descr='Do not scrub' DiskScrub='no' BiosScrub='no' />
#    <Var Name='DiskScrub' Descr='Scrub disk' DiskScrub='yes' BiosScrub='no' />
#    <Var Name='BiosScrub' Descr='Scrub Bios' DiskScrub='no' BiosScrub='yes' />
#    <Var Name='AllScrub' Descr='Scrub disk and Bios' DiskScrub='yes' BiosScrub='yes' />
#  </ScrubPolicy>

$tmp1 = $ucsConfig.VSPEX.ScrubPolicy
If ($tmp1 -ne $null)
{
    For ($i=0; $i -lt $objectTable.length; $i++)
    {
        $obj = $objectTable[$i]
        If ($obj[0] -eq 'ScrubPolicy') {$obj[1] = 1; Break}
    }
    $ucsConfig.VSPEX.ScrubPolicy | ForEach-Object {$_.Var} | ForEach-Object {
        $tmp1 = $_.Name.trim()
        $tmp2 = $_.Descr
        $tmp3 = $_.DiskScrub.trim()
        $tmp3 = $tmp3.tolower()
        $tmp4 = $_.BiosScrub.trim()
        $tmp4 = $tmp4.tolower()

        If (($tmp3 -eq 'yes' -or $tmp3 -eq 'no') -and ($tmp4 -eq 'yes' -or $tmp4 -eq 'no'))
        {
           Write-Log "Valid Scrub Policy on entry - Name=$tmp1 Descr=$tmp2 Disk=$tmp3 Bios=$tmp4" "Normal"
        }
        Else
        {
            Write-Log "Invalid Scrub Policy on entry - Name=$tmp1 Descr=$tmp2 Disk=$tmp3 Bios=$tmp4" "Error"
            $errTag = $True
        }
    }
}

##########
# Validate Maintenance Policies
# Input sample:
#  <MaintenancePolicy>
#    <Var Name='Immediate' Descr='Immediately reboot on profile change' Policy='immediate' />
#    <Var Name='UserAck' Descr='User acknowledge reboot on profile change' Policy='user-ack' />
#    <Var Name='Timer-auto' Descr='Timer reboot on default schedule' Policy='timer-automatic' />
#  </MaintenancePolicy>

$tmp1 = $ucsConfig.VSPEX.MaintenancePolicy
If ($tmp1 -ne $null)
{
    For ($i=0; $i -lt $objectTable.length; $i++)
    {
        $obj = $objectTable[$i]
        If ($obj[0] -eq 'MaintenancePolicy') {$obj[1] = 1; Break}
    }
    $ucsConfig.VSPEX.MaintenancePolicy | ForEach-Object {$_.Var} | ForEach-Object {
        $tmp1 = $_.Name.trim()
        $tmp2 = $_.Descr.trim()
        $tmp3 = $_.Policy.trim()
        $tmp3 = $tmp3.tolower()
        If ($tmp3 -eq 'immediate' -or $tmp3 -eq 'timer-automatic' -or $tmp3 -eq 'user-ack')
        {
           Write-Log "Valid Maintenance Policy on entry - Name=$tmp1 Descr=$tmp2 Policy=$tmp3" "Normal"
        }
        Else
        {
            Write-Log "Invalid Maintenance Policy on entry - Name=$tmp1 Descr=$tmp2 Policy=$tmp3" "Error"
            $errTag = $True
        }
    }
}

##########
# Validate Local Disk Policies
# Input sample:
#  <DiskPolicy>
#    <Var Name='AnyConfiguration' Mode='any-configuration' Descr='Any Disk Configuration' Protect='yes' />
#    <Var Name='NoLocal' Mode='no-local-storage' Descr='Ignore local storage' Protect='yes' />
#    <Var Name='NoRAID' Mode='no-raid' Descr='No RAID storage' Protect='yes' />
#    <Var Name='RAID0' Mode='raid-striped' Descr='RAID 0 Striped' Protect='yes' />
#    <Var Name='RAID1' Mode='raid-mirrored' Descr='RAID 1 Mirrored' Protect='yes' />
#    <Var Name='RAID10' Mode='raid-mirrored-striped' Descr='RAID 10 Mirrored and Striped' Protect='yes' />
#    <Var Name='RAID5' Mode='raid-striped-parity' Descr='RAID 5 Striped Parity' Protect='yes' />
#    <Var Name='RAID6' Mode='raid-striped-dual-parity' Descr='RAID 6 Striped Dual Parity' Protect='yes' />
#  </DiskPolicy>

$tmp1 = $ucsConfig.VSPEX.DiskPolicy
If ($tmp1 -ne $null)
{
    For ($i=0; $i -lt $objectTable.length; $i++)
    {
        $obj = $objectTable[$i]
        If ($obj[0] -eq 'DiskPolicy') {$obj[1] = 1; Break}
    }
    $ucsConfig.VSPEX.DiskPolicy | ForEach-Object {$_.Var} | ForEach-Object {
        $tmp1 = $_.Name.trim()
        $tmp2 = $_.Mode.trim()
        $tmp3 = $_.Protect.trim()
        For ($i=0; $i -lt $diskPolicyOptions.length; $i++)
        {
            If (($tmp2 -eq $diskPolicyOptions[$i]) -and ($tmp3 -eq 'yes' -or $tmp3 -eq 'no'))
            {
                Write-Log "Valid local disk policy - Name=$tmp1 Mode=$tmp2 Protect=$tmp3" "Normal"
                Break
            }
        }
        If ($i -eq $diskPolicyOptions.Length)
        {
            Write-Log "Invalid local disk policy - Name=$tmp1 Mode=$tmp2 Protect=$tmp3" "Error"
            $errTag = $True
        }
    }
}

##########
# Validate FI port definitions  - NOTE: this section does not handle FC ports.
# Input sample:
#  <FI>
#    <Var SlotID='1' PortID='1' Role='Server' UsrLbl='Blade Server' VLAN='n/a' Native='n/a' Mode='n/a' QoS='n/a' />
#    <Var SlotID='1' PortID='2' Role='Server' UsrLbl='Blade Server' VLAN='n/a' Native='n/a' Mode='n/a' QoS='n/a' />
#    <Var SlotID='1' PortID='5' Role='' UsrLbl='' VLAN='n/a' Native='n/a' Mode='n/a' QoS='n/a' />
#    <Var SlotID='1' PortID='6' Role='' UsrLbl='' VLAN='n/a' Native='n/a' Mode='n/a' QoS='n/a' />
#    <Var SlotID='1' PortID='17' Role='Uplink' UsrLbl='Uplink Port' VLAN='n/a' Native='n/a' Mode='n/a' QoS='n/a' />
#    <Var SlotID='1' PortID='18' Role='Uplink' UsrLbl='Uplink Port' VLAN='n/a' Native='n/a' Mode='n/a' QoS='n/a' />
#    <Var SlotID='1' PortID='23' Role='Appliance' UsrLbl='10 GE SMB' VLAN='SMB' Native='no' Mode='Access' QoS='gold' />
#    <Var SlotID='1' PortID='24' Role='Appliance' UsrLbl='10 GE SMB' VLAN='SMB' Native='no' Mode='Access' QoS='gold' />
#    <Var SlotID='1' PortID='27' Role='' UsrLbl='' VLAN='' Native='no' Mode='Access' QoS='n/a' />
#    <Var SlotID='1' PortID='28' Role='' UsrLbl='' VLAN='' Native='no' Mode='Access' QoS='n/a' />
#    <Var SlotID='2' PortID='1' Role='' UsrLbl='' VLAN='n/a' Native='n/a' Mode='n/a' QoS='n/a' />
#    <Var SlotID='2' PortID='2' Role='' UsrLbl='' VLAN='n/a' Native='n/a' Mode='n/a' QoS='n/a' />
#  </FI>

$tmp1 = $ucsConfig.VSPEX.FI.Var
If ($tmp1 -ne $null)
{
    For ($i=0; $i -lt $objectTable.length; $i++)
    {
        $obj = $objectTable[$i]
        If ($obj[0] -eq 'FI') {$obj[1] = 1; Break}
    }
    $ucsConfig.VSPEX.FI | ForEach-Object {$_.Var} | ForEach-Object {
        $tmp1 = $_.SlotID.trim()
        $tmp2 = $_.PortID.trim()
        $tmp3 = $_.Role.trim()
        If ($tmp1 -eq '1')
        {
            For ($i=0; $i -lt $fiPortRoles.length; $i++)
            {
                If (([int]$tmp2 -ge 1 -and [int]$tmp2 -le 32) -and ($tmp3 -eq $fiPortRoles[$i]))
                {
                    If ($tmp3 -ne '')
                    {
                        Write-Log "Valid FI port role definition - SlotID=$tmp1 PortID=$tmp2 Role=$tmp3" "Normal"
                    }
                    Break
                }
            }
            If ($i -eq $fiPortRoles.length)
            {
                Write-Log "Invalid FI port role definition - SlotID=$tmp1 PortID=$tmp2 Role=$tmp3" "Error"
                $errTag = $True
            }
        }
        If ($tmp1 -eq '2')
        {
            For ($i=0; $i -lt $fiPortRoles.length; $i++)
            {
                If (([int]$tmp2 -ge 1 -and [int]$tmp2 -le 16) -and ($tmp3 -eq $fiPortRoles[$i]))
                {
                    If ($tmp3 -ne '')
                    {
                        Write-Log "Valid FI port role definition - SlotID=$tmp1 PortID=$tmp2 Role=$tmp3" "Normal"
                    }
                    Break
                }
            }
            If ($i -eq $fiPortRoles.length)
            {
                Write-Log "Invalid FI port role definition - SlotID=$tmp1 PortID=$tmp2 Role=$tmp3" "Error"
                $errTag = $True
            }
        }
        If ($tmp1 -ne '1' -and $tmp1 -ne '2')
        {
            Write-Log "Invalid Slot number - $tmp1" "Error"
            $errTag = $true
        }
    }
}

##########
# Validate FC port definitions  - NOTE: this section handles FC ports.
# Input sample:
#  <FCslot1 PortID='' UsrLbl='' />
#  <FCslot2 PortID='' UsrLbl='' />

$tmp1 = $ucsConfig.VSPEX.FCslot1.PortID
If ($tmp1 -ne $null)
{
    For ($i=0; $i -lt $objectTable.length; $i++)
    {
        $obj = $objectTable[$i]
        If ($obj[0] -eq 'FCslot1') {$obj[1] = 1; Break}
    }
    $tmp1 = $tmp1.trim()
    If ($tmp1 -ne '')
    {
        If (($tmp1 % 2 -eq 0) -or ($tmp1 -ge 32))
        {
            Write-Log "Invalid Fixed Module FC Port - must not be an even integer or > 31 - $tmp1" "Error"
            $errTag = $true
        }
        Else
        {
            Write-Log "Valid Fixed Module FC port starting at - Port=$tmp1" "Normal"
        }
    }
}

$tmp1 = $ucsConfig.VSPEX.FCslot2.PortID
If ($tmp1 -ne $null)
{
    For ($i=0; $i -lt $objectTable.length; $i++)
    {
        $obj = $objectTable[$i]
        If ($obj[0] -eq 'FCslot2') {$obj[1] = 1; Break}
    }
    $tmp1 = $tmp1.trim()
    If ($tmp1 -ne '')
    {
        If (($tmp1 % 2 -eq 0) -or ($tmp1 -ge 16))
        {
            Write-Log "Invalid Expansion Module FC Port - must not be an even integer or > 15 - $tmp1" "Error"
            $errTag = $true
        }
        Else
        {
            Write-Log "Valid Expansion Module FC port starting at - Port=$tmp1" "Normal"
        }
    }
}

##########
# Validate Port Channel configuration
# Input sample:
#  <PC>
#    <AName>VPC201 </AName>
#    <APortID>201 </APortID>
#    <BName>VPC202 </BName>
#    <BPortID>202 </BPortID>
#    <Slot>1 </Slot>
#    <Port1>17 </Port1>
#    <Port2>18 </Port2>
#  </PC>

$tmp = $False
$tmp1 = $ucsConfig.VSPEX.PC.AName
$tmp2 = $ucsConfig.VSPEX.PC.BName
$tmp3 = $ucsConfig.VSPEX.PC.APortID
$tmp4 = $ucsConfig.VSPEX.PC.BPortID
$tmp5 = $ucsConfig.VSPEX.PC.Slot
$tmp6 = $ucsConfig.VSPEX.PC.Port1
$tmp7 = $ucsConfig.VSPEX.PC.Port2

If ($tmp1 -ne $null -and $tmp2 -ne $null)
{
    For ($i=0; $i -lt $objectTable.length; $i++)
    {
        $obj = $objectTable[$i]
        If ($obj[0] -eq 'PC') {$obj[1] = 1; Break}
    }
    $tmp1 = $tmp1.trim()
    $tmp2 = $tmp2.trim()
    $tmp3 = $tmp3.trim()
    $tmp4 = $tmp4.trim()
    $tmp5 = $tmp5.trim()
    $tmp6 = $tmp6.trim()
    $tmp7 = $tmp7.trim()
    If ($tmp1 -eq $tmp2)
    {
        Write-Log "Port Channel names must be different on each fabric - A-Name=$tmp1 B-Name=$tmp2" "Error"
        $tmp = $True
    }

    If ($tmp3 -eq $tmp4)
    {
        Write-Log "Port Channel PortID must be different on each fabric - A-PortID=$tmp3 B-PortID$tmp4" "Error"
        $tmp = $True
    }

    If ($tmp5 -ne '1' -and $tmp5 -ne '2')
    {
        Write-Log "Port Channel Slot must be '1' or '2' - SlitID=$tmp5" "Error"
        $tmp = $True
    }
    Else
    {
        Switch ($tmp5)
        {
            1
            {
                If (([int]$tmp6 -lt 1 -or [int]$tmp6 -gt 32) -or ([int]$tmp7 -lt 1 -or [int]$tmp7 -gt 32) -or ($tmp6 -eq $tmp7))
                {
                    Write-Log "Invalid port number for Slot 1 - Port1=$tmp6 Port2=$tmp7" "Error"
                    $tmp = $True
                }
            }
            2
            {
                If (([int]$tmp6 -lt 1 -or [int]$tmp6 -gt 16) -or ([int]$tmp7 -lt 1 -or [int]$tmp7 -gt 16) -or ($tmp6 -eq $tmp7))
                {
                    Write-Log "Invalid port number for Slot 2 - Port1=$tmp6 Port2=$tmp7" "Error"
                    $tmp = $True
                }
            }
        }
    }
}

If (!$tmp)
{
    Write-Log "Fabric A VPC - A-Name=$tmp1 A-PortID=$tmp3 Slot=$tmp5 Port1=$tmp6 Port2=$tmp7" "Normal"
    Write-Log "Fabric B VPC - B-Name=$tmp2 B-PortID=$tmp4 Slot=$tmp5 Port1=$tmp6 Port2=$tmp7" "Normal"
}
Else
{
    Write-Log "Invalid fabric A VPC - A-Name=$tmp1 A-PortID=$tmp3 Slot=$tmp5 Port1=$tmp6 Port2=$tmp7" "Normal"
    Write-Log "Invalid fabric B VPC - B-Name=$tmp2 B-PortID=$tmp4 Slot=$tmp5 Port1=$tmp6 Port2=$tmp7" "Normal"
    $errTag = $True
}

##########
# Validate the various types of pools
# Input sample:
#  <Pools>
#    <Var Type='MAC' Name='VSPEX-99-MAC' From='00:25:B5:99:00:00' To='00:25:B5:99:00:FF' Order='sequential' Org='VSPEX' Descr='' />
#    <Var Type='UUID' Name='VSPEX-99-UUID' From='0099-000000000001' To='0099-000000000040' Order='sequential' Org='VSPEX' Descr='' />
#    <Var Type='WWNN' Name='VSPEX-99-WWNN' From='20:00:00:25:B5:99:00:00' To='20:00:00:25:B5:99:00:3F' Order='sequential' Org='VSPEX' Descr='' />
#    <Var Type='WWPN' Name='VSPEX-99-WWPN' From='20:00:00:25:B5:99:00:40' To='20:00:00:25:B5:99:00:FF' Order='sequential' Org='VSPEX' Descr='' />
#  </Pools>

$tmp1 = $ucsConfig.VSPEX.Pools
If ($tmp1 -ne $null)
{
    For ($i=0; $i -lt $objectTable.length; $i++)
    {
        $obj = $objectTable[$i]
        If ($obj[0] -eq 'Pools') {$obj[1] = 1; Break}
    }
    $ucsConfig.VSPEX.Pools | ForEach-Object {$_.Var} | ForEach-Object {
        $tmp1 = $_.Type.trim()
        $tmp2 = $_.Name.trim()
        $tmp3 = $_.From.trim()
        $tmp4 = $_.To.trim()
        If ($tmp2 -eq 'default') {$tmp2 = $tmp2.tolower()}
        For ($i=0; $i -lt $poolType.length; $i++)
        {
            If ($tmp1 -eq $poolType[$i])
            {
                Switch ($tmp1)
                {
                    MAC
                    {
                        If (($tmp3 -match $validMAC -and $tmp4 -match $validMAC) -and ($tmp3 -lt $tmp4))
                        {
                            Write-Log "Valid MAC pool - Name=$tmp2 From=$tmp3 To=$tmp4" "Normal"
                        }
                        Else
                        {
                            Write-Log "Invalid MAC pool - Name=$tmp2 From=$tmp3 To=$tmp4" "Error"
                            $errTag = $True
                        }
                    }
                    UUID
                    {
                        If (($tmp3 -match $validUUID -and $tmp4 -match $validUUID) -and ($tmp3 -lt $tmp4))
                        {
                            Write-Log "Valid UUID pool - Name=$tmp2 From=$tmp3 To=$tmp4" "Normal"
                        }
                        Else
                        {
                            Write-Log "Invalid UUID pool - Name=$tmp2 From=$tmp3 To=$tmp4" "Error"
                            $errTag = $True
                        }
                    }
                    WWNN
                    {
                        If (($tmp3 -match $validWWN -and $tmp4 -match $validWWN) -and ($tmp3 -lt $tmp4))
                        {
                            Write-Log "Valid WWNN pool - Name=$tmp2 From=$tmp3 To=$tmp4" "Normal"
                        }
                        Else
                        {
                            Write-Log "Invalid WWNN pool - Name=$tmp2 From=$tmp3 To=$tmp4" "Error"
                            $errTag = $True
                        }
                    }
                    WWPN
                    {
                        If (($tmp3 -match $validWWPN -and $tmp4 -match $validWWPN) -and ($tmp3 -lt $tmp4))
                        {
                            Write-Log "Valid WWPN pool - Name=$tmp2 From=$tmp3 To=$tmp4" "Normal"
                        }
                        Else
                        {
                            Write-Log "Invalid WWPN pool - Name=$tmp2 From=$tmp3 To=$tmp4" "Error"
                            $errTag = $True
                        }
                    }
                }
            Break
            }
        }
        If ($i -eq $poolType.length)
        {
            Write-Log "Invalid pool type - Type=$tmp1 Name=$tmp2 From=$tmp3 To=$tmp4" "Error"
            $errTag = $True
        }
    }
}

##########
#Validate VLAN definitions
# Input sample:
#  <VLANs>
#    <Var Name='Mgmt' Fabric='Common' ATag='1' BTag='' DefaultNet="yes" />
#    <Var Name='VMaccess' Fabric='Common' ATag='10' BTag='' DefaultNet="no" />
#    <Var Name='CSV' Fabric='Common' ATag='12' BTag='' DefaultNet="no" />
#    <Var Name='LiveMigration' Fabric='Common' ATag='11' BTag='' DefaultNet="no" />
#    <Var Name='ClusComm' Fabric='Common' ATag='13' BTag='' DefaultNet="no" />
#    <Var Name='SMB' Fabric='Diff' ATag='16' BTag='17' DefaultNet="no" />
#    <Var Name='VEM' Fabric='Common' ATag='100' BTag='' DefaultNet="no" />
#  </VLANs>

$tmp1 = $ucsConfig.VSPEX.VLANs
If ($tmp1 -ne $null)
{
    For ($i=0; $i -lt $objectTable.length; $i++)
    {
        $obj = $objectTable[$i]
        If ($obj[0] -eq 'VLANs') {$obj[1] = 1; Break}
    }
    $ucsConfig.VSPEX.VLANs | ForEach-Object {$_.Var} | ForEach-Object {
        $tmp1 = $_.Name.trim()
        $tmp2 = $_.Fabric.trim()
        $tmp3 = $_.ATag.trim()
        $tmp4 = $_.BTag.trim()
        $tmp5 = $_.DefaultNet.trim()
        If ($tmp2 -eq 'common' -or $tmp2 -eq 'diff' -or $tmp2 -eq 'faba' -or $tmp2 -eq 'fabb')
        {
            $tmp = $False
            If (!($tmp5 -eq 'yes' -or $tmp5 -eq 'no'))
            {
                Write-Log "Invalid default net value - Name=$tmp1 DefaultNet=$tmp5" "Error"
                $tmp = $True
            }
            Switch ($tmp2)
            {
                common
                {
                    If (!(($tmp3 -eq '') -or ([int]$tmp3 -ge 1 -and [int]$tmp3 -le 4095)))
                    {
                        Write-Log "Invalid VLAN tag value - Name=$tmp1 Fabric=$tmp2 ATag=$tmp3" "Error"
                        $tmp = $true
                    }
                }
                diff
                {
                    If (!(($tmp3 -eq '') -or ([int]$tmp3 -ge 1 -and [int]$tmp3 -le 4095)))
                    {
                        Write-Log "Invalid VLAN tag value - Name=$tmp1 Fabric=$tmp2 ATag=$tmp3" "Error"
                        $tmp = $True
                    }
                    If (!(($tmp4 -eq '') -or ([int]$tmp4 -ge 1 -and [int]$tmp4 -le 4095)))
                    {
                        Write-Log "Invalid VLAN tag value - Name=$tmp1 Fabric=$tmp2 BTag=$tmp4" "Error"
                        $tmp = $true
                    }
                }
                faba
                {
                    If (!(($tmp3 -eq '') -or ([int]$tmp3 -ge 1 -and [int]$tmp3 -le 4095)))
                    {
                        Write-Log "Invalid VLAN tag value - Name=$tmp1 Fabric=$tmp2 ATag=$tmp3" "Error"
                        $tmp = $True
                    }
                }
                fabb
                {
                    If (!(($tmp4 -eq '') -or ([int]$tmp4 -ge 1 -and [int]$tmp4 -le 4095)))
                    {
                        Write-Log "Invalid VLAN tag value - Name=$tmp1 Fabric=$tmp2 BTag=$tmp4" "Error"
                        $tmp = $true
                    }
                }
            }
            If (!$tmp)
            {
                Write-Log "Valid VLAN definition - Name=$tmp1 Fabric=$tmp2 ATag=$tmp3 BTag=$tmp4 DefaultNet=$tmp5" "Normal"
            }
            Else
            {
                Write-Log "Invalid VLAN definition - Name=$tmp1 Fabric=$tmp2 ATag=$tmp3 BTag=$tmp4 DefaultNet=$tmp5" "Error"
                $errTag = $True
            }
        }
        Else
        {
            Write-Log "Invalid fabric configuration - Name=$tmp1 Fabric=$tmp2" "Error"
            $errTag = $True
        }
    }
}

##########
# Validate VNIC template information
# Input sample:
#  <VNICtemplate>
#    <Var Name='Mgmt' MTU='1500' Fabric='A-B' MACpool='VSPEX-99-MAC' Qos='' VLAN='Mgmt' Order='1' Type='updating-template' Native='yes' Org='root' />
#    <Var Name='CSV' MTU='9000' Fabric='A-B' MACpool='VSPEX-99-MAC' Qos='' VLAN='CSV' Order='2' Type='updating-template' Native='yes' Org='root' />
#    <Var Name='LiveMigration' MTU='9000' Fabric='A-B' MACpool='VSPEX-99-MAC' Qos='LiveMigration' VLAN='LiveMigration' Order='3' Type='updating-template' Native='yes' Org='root' />
#    <Var Name='VMaccess' MTU='1500' Fabric='B-A' MACpool='VSPEX-99-MAC' Qos='' VLAN='VMaccess' Order='4' Type='updating-template' Native='no' Org='root' />
#    <Var Name='ClusComm' MTU='1500' Fabric='B-A' MACpool='VSPEX-99-MAC' Qos='' VLAN='ClusComm' Order='5' Type='updating-template' Native='no' Org='root' />
#    <Var Name='SMB-A' MTU='9000' Fabric='A-B' MACpool='VSPEX-99-MAC' Qos='iSCSI' VLAN='SMB' Order='8' Type='updating-template' Native='no' Org='root' />
#    <Var Name='SMB-B' MTU='9000' Fabric='B-A' MACpool='VSPEX-99-MAC' Qos='iSCSI' VLAN='SMB' Order='9' Type='updating-template' Native='no' Org='root' />
#    <Var Name='VEM' MTU='1500' Fabric='B-A' MACpool='VSPEX-99-MAC' Qos='' VLAN='VEM' Order='10' Type='updating-template' Native='no' Org='root' />
#  </VNICtemplate>

$tmp1 = $ucsConfig.VSPEX.VNICTemplate
If ($tmp1 -ne $null)
{
    For ($i=0; $i -lt $objectTable.length; $i++)
    {
        $obj = $objectTable[$i]
        If ($obj[0] -eq 'VNICTemplate') {$obj[1] = 1; Break}
    }
    $ucsConfig.VSPEX.VNICTemplate | ForEach-Object {$_.Var} | ForEach-Object {
        $tmp = $False
        $tmp1 = $_.Name
        $tmp2 = $_.MTU.trim()
        If (!($tmp2 -eq '1500' -or $tmp2 -eq '9000'))
        {
            Write-Log "Invalid MTU - should be 1500 or 9000 - Name=$tmp1 MTU=$tmp2" "Error"
            $tmp = $true
        }
        $tmp3 = $_.Fabric.trim()
        $tmp3 = $tmp3.toupper()
        If (!($tmp3 -eq 'A-B' -or $tmp3 -eq 'B-A'))
        {
            Write-Log "Invalid fabric - should be A-B or B-A - Name=$tmp1 Fabric=$tmp3" "Error"
            $tmp = $true
        }
        $tmp4 = $_.Type.trim()
        $tmp4 = $tmp4.tolower()
        If (!($tmp4 -eq 'updating-template' -or $tmp4 -eq 'initial-template'))
        {
            Write-Log "Invalid template type - Name=$tmp1 Type=$tmp4" "Error"
            $tmp = $true
        }
        $tmp5 = $_.Native.trim()
        $tmp5 = $tmp5.tolower()
        If (!($tmp5 -eq 'no' -or $tmp5 -eq 'yes'))
        {
            Write-Log "Invalid native mode - must be yes or no - Native=$tmp5" "Error"
            $tmp = $true
        }
        If (!$tmp)
        {
            Write-Log "Valid VNIC template - Name=$tmp1 MTU=$tmp2 Fabric=$tmp3 Type=$tmp4 Native=$tmp5" "Normal"
        }
        Else
        {
            Write-Log "Invalid VNIC template - Name=$tmp1 MTU=$tmp2 Fabric=$tmp3 Type=$tmp4 Native=$tmp5" "Error"
            $errTag = $True
        }
    }
}

##########
# Validate virtual HBA template
# Input sample:   <Var Name='FabChn-A' Descr='Fabric A vHBA' Fabric='A' VSAN='default' Type='updating-template' WWNpool='Pool-AF' Qos='' />

$tmp1 = $ucsConfig.VSPEX.VHBATemplate
If ($tmp1 -ne $null)
{
    For ($i=0; $i -lt $objectTable.length; $i++)
    {
        $obj = $objectTable[$i]
        If ($obj[0] -eq 'VHBATemplate') {$obj[1] = 1; Break}
    }
    $ucsConfig.VSPEX.VHBATemplate | ForEach-Object {$_.Var} | ForEach-Object {
        $tmp = $False
        $tmp1 = $_.Name.trim()
        $tmp2 = $_.Fabric.trim()
        $tmp3 = $_.Type.trim()
        If ($tmp1 -eq '')
        {
            Write-Log "Missing name for vHBA template - Fabric=$tmp2 Type=$tmp3" "Error"
            $tmp = $True
        }
        If (!($tmp2 -eq 'A' -or $tmp2 -eq 'B'))
        {
            Write-Log "Invalid Fabric for vHBA template - Name=$tmp1 Fabric=$tmp2" "Error"
            $tmp = $True
        }
        If (!($tmp3 -eq 'initial-template' -or $tmp3 -eq 'updating-template'))
        {
            Write-Log "Invalid template type for vHBA template - Name=$tmp1 Type=$tmp3" "Error"
            $tmp = $True
        }
        If (!$tmp)
        {
            Write-Log "Valid vHBA template - Name=$tmp1 Fabric=$tmp2 Type=$tmp3" "Normal"
        }
        Else
        {
            Write-Log "Invalid vHBA template - Name=$tmp1 Fabric=$tmp2 Type=$tmp3" "Normal"
            $errTag = $True
        }
    }
}

##########
# Validate boot policies
# Input sample:
#  <BootPolicy>
#    <PolicyName Name='VSPEX-SAN-A-Boot' Descr='Fibre Channel Boot Fabric A' Org='VSPEX' >
#      <Var Type='Local' Device1='cdrom' Device2='' PrimaryFabric='' />
#      <Var Type='VHBA' Device1='FabChn-A' Device2='FabChn-B' PrimaryFabric='A' />
#    </PolicyName>
#    <PolicyName Name='VSPEX-SAN-B-Boot' Descr='Fibre Channel Boot Fabric B' Org='VSPEX' >
#      <Var Type='Local' Device1='cdrom' Device2='' PrimaryFabric='' />
#      <Var Type='VHBA' Device1='FabChn-B' Device2='FabChn-A' PrimaryFabric='B' />
#    </PolicyName>
#  </BootPolicy>

$tmp1 = $ucsConfig.VSPEX.BootPolicy
If ($tmp1 -ne $null)
{
    For ($i=0; $i -lt $objectTable.length; $i++)
    {
        $obj = $objectTable[$i]
        If ($obj[0] -eq 'BootPolicy') {$obj[1] = 1; Break}
    }
    $ucsConfig.VSPEX.BootPolicy | ForEach-Object {$_.PolicyName} | ForEach-Object {
        $tmp1 = $_
        $tmp2 = $_.Name.trim()
        $tmp1 | ForEach-Object {$_.Var} | ForEach-Object {
            $tmp = $False
            $tmp3 = $_.Type.trim()
            $tmp4 = $_.Device1.trim()
            $tmp5 = $_.Device2.trim()
            $tmp6 = $_.PrimaryFabric
            If (!($tmp3 -eq 'Local' -or $tmp3 -eq 'VNIC' -or $tmp3 -eq 'VHBA'))
            {
                Write-Log "Device type must be Local, VNIC, or VHBA - Name=$tmp2 Type=$tmp3" "Error"
                $tmp = $True
            }
            If ($tmp3 -eq 'Local')
            {
                If (!($tmp4 -eq 'localdisk' -or $tmp4 -eq 'cdrom' -or $tmp4 -eq 'floppy'))
                {
                    Write-Log "Local device must be localdisk, cdrom, or floppy - Name=$tmp2 Device1=$tmp4" "Error"
                    $tmp = $True
                }
            }
            If ($tmp5 -ne '')
            {
                If (!($tmp6 -eq 'A' -or $tmp6 -eq 'B'))
                {
                    Write-Log "Primary Fabric must be A or B - Name=$tmp2 Device1=$tmp4" "Error"
                    $tmp = $True
                }
            }
            If (!$tmp)
            {
                Write-Log "Valid boot policy - Name=$tmp2 Type=$tmp3 Device1=$tmp4 Device2=$tmp5" "Normal"
            }
            Else
            {
                Write-Log "Invalid boot policy - Name=$tmp2 Type=$tmp3 Device1=$tmp4 Device2=$tmp5" "Error"
                $errTag = $True
            }
        }
    }
}

##########
# TimeZone - just check for presence - no validation - accept what is there
# Input sample:   <TimeZone>America/Los_Angeles (Pacific Time) </TimeZone>

$tmp1 = $ucsConfig.VSPEX.TimeZone
If ($tmp1 -ne $null)
{
    For ($i=0; $i -lt $objectTable.length; $i++)
    {
        $obj = $objectTable[$i]
        If ($obj[0] -eq 'TimeZone') {$obj[1] = 1; Break}
    }
}

##########
# NTP - just check for presence - no validation - accept what is there
# Input sample: 
#  <NTP>
#    <Var Name='1.ntp.esl.cisco.com' />
#    <Var Name='2.ntp.esl.cisco.com' />
#  </NTP>

$tmp1 = $ucsConfig.VSPEX.NTP.Var
If ($tmp1 -ne $null)
{
    For ($i=0; $i -lt $objectTable.length; $i++)
    {
        $obj = $objectTable[$i]
        If ($obj[0] -eq 'NTP') {$obj[1] = 1; Break}
    }
}

##########
# CallHome - just check for presence - no validation - accept what is there
# Input sample:
#  <CallHome>
#    <InUse>0 </InUse>  <!-- To define, InUse=1.  To not define, InUse=0. -->
#    <SmtpSrv>smtprelay.customer.com </SmtpSrv>
#    <Address>123 Main Street, Anytown, CA 54321 </Address>
#    <ContactName>First Last </ContactName>
#    <ContactPhone>+15551234567 </ContactPhone>
#    <ContactEmail>contact@customer.com </ContactEmail>
#    <CustomerID>12345 </CustomerID>
#    <ContractID>12345 </ContractID>
#    <SiteID>12345 </SiteID>
#    <SmtpFrom>UCSstringCallHome@customer.com </SmtpFrom>
#    <SmtpRecipient>contact@customer.com </SmtpRecipient>
#  </CallHome>

$tmp1 = $ucsConfig.VSPEX.CallHome.InUse
If ($tmp1 -ne $null)
{
    For ($i=0; $i -lt $objectTable.length; $i++)
    {
        $obj = $objectTable[$i]
        If ($obj[0] -eq 'CallHome') {$obj[1] = 1; Break}
    }
}

##########
# SubOrg - just check for presence - no validation - accept what is there
# Input sample:
#  <SubOrg>
#    <Var Name='VSPEX' Descr='For all VSPEX work' />
#  </SubOrg>

$tmp1 = $ucsConfig.VSPEX.SubOrg.Var
If ($tmp1 -ne $null)
{
    For ($i=0; $i -lt $objectTable.length; $i++)
    {
        $obj = $objectTable[$i]
        If ($obj[0] -eq 'SubOrg') {$obj[1] = 1; Break}
    }
}

##########
# QoS - just check for presence - no validation - accept what is there
# Input sample: 
#  <QoS>
#    <Platinum>LiveMigration </Platinum>
#    <Gold>iSCSI </Gold>
#    <Silver> </Silver>
#    <Bronze> </Bronze>
#  </QoS>

$tmp1 = $ucsConfig.VSPEX.QoS
If ($tmp1 -ne $null)
{
    For ($i=0; $i -lt $objectTable.length; $i++)
    {
        $obj = $objectTable[$i]
        If ($obj[0] -eq 'QoS') {$obj[1] = 1; Break}
    }
}

##########
# BIOSPolicy - just check for presence - no validation - accept what is there
# Input sample:
#  <BIOSPolicy>
#    <Var Name='NoQuietBoot' Descr= 'No quiet boot' VpQuietBoot='disabled' />
#  </BIOSPolicy>

$tmp1 = $ucsConfig.VSPEX.BIOSPolicy.Var
If ($tmp1 -ne $null)
{
    For ($i=0; $i -lt $objectTable.length; $i++)
    {
        $obj = $objectTable[$i]
        If ($obj[0] -eq 'BIOSPolicy') {$obj[1] = 1; Break}
    }
}

##########
# PlacementPolicy - just check for presence - no validation - accept what is there
# Input sample:
#  <PlacementPolicy>
#    <Var Name='AssignedOnly' SlotMapping='round-robin' Selection='assigned-only' />
#    <Var Name='ExcludeDynamic' SlotMapping='round-robin' Selection='exclude-dynamic' />
#    <Var Name='ExcludeUnassign' SlotMapping='round-robin' Selection='exclude-unassigned' />
#  </PlacementPolicy>

$tmp1 = $ucsConfig.VSPEX.PlacementPolicy.Var
If ($tmp1 -ne $null)
{
    For ($i=0; $i -lt $objectTable.length; $i++)
    {
        $obj = $objectTable[$i]
        If ($obj[0] -eq 'PlacementPolicy') {$obj[1] = 1; Break}
    }
}

##########
# Service Profile Template - just check for presence - no validation - accept what is there
# Input sample:
#  <SPTemplate>
#    <Template>
#      <Name>VSPEX-99-BootA </Name>
#      <Descr>VSPEX-99 Boot from SAN Fabric A </Descr>
#      <BIOSProfileName> </BIOSProfileName>
#      <BootPolicyName>VSPEX-SAN-A-Boot </BootPolicyName>
#      <LocalDiskPolicy>NoLocal </LocalDiskPolicy>
#      <MgmtIPpool>MgmtIP </MgmtIPpool>
#      <PowerPolicyName>NoCap </PowerPolicyName>
#      <ScrubPolicyName>NoScrub </ScrubPolicyName>
#      <UUIDpool>VSPEX-99-UUID </UUIDpool>
#      <MaintPolicyName>UserAck </MaintPolicyName>
#      <HostFwPolicyName> </HostFwPolicyName>
#      <MgmtAccessPolicyName> </MgmtAccessPolicyName>
#      <MgmtFwPolicyName> </MgmtFwPolicyName>
#      <StatsPolicyName>default </StatsPolicyName>
#      <Org>VSPEX </Org>
#      <WwnnPoolName>VSPEX-99-WWNN </WwnnPoolName>
#      <VNICs>
#        <Var Name='Mgmt' Templ='Mgmt' />
#        <Var Name='LiveMigration' Templ='LiveMigration' />
#        <Var Name='CSV' Templ='CSV' />
#        <Var Name='VMaccess' Templ='VMaccess' />
#        <Var Name='ClusComm' Templ='ClusComm' />
#        <Var Name='VEM' Templ='VEM' />
#      </VNICs>
#      <VHBAs>
#        <Var Name='FabChn-A' Templ='VSPEX-99-FabA'/>  <!-- Name must match value of Devicex in boot policy -->
#        <Var Name='FabChn-B' Templ='VSPEX-99-FabB'/>
#      </VHBAs>
#    </Template>
#  </SPTemplate>
$tmp1 = $ucsConfig.VSPEX.SPTemplate.Template
If ($tmp1 -ne $null)
{
    For ($i=0; $i -lt $objectTable.length; $i++)
    {
        $obj = $objectTable[$i]
        If ($obj[0] -eq 'SPTemplate') {$obj[1] = 1; Break}
    }
}

##########
# ServiceProfile - just check for presence - no validation - accept what is there
# Input sample:
#  <ServiceProfile>
#    <Var Name='VSPEX-01' Templ='VSPEX-99-BootA' Org='VSPEX' />
#    <Var Name='VSPEX-02' Templ='VSPEX-99-BootB' Org='VSPEX' />
#    <Var Name='VSPEX-03' Templ='VSPEX-99-BootA' Org='VSPEX' />
#    <Var Name='VSPEX-04' Templ='VSPEX-99-BootB' Org='VSPEX' />
#    <Var Name='VSPEX-05' Templ='VSPEX-99-BootA' Org='VSPEX' />
#    <Var Name='VSPEX-06' Templ='VSPEX-99-BootB' Org='VSPEX' />
#  </ServiceProfile>

$tmp1 = $ucsConfig.VSPEX.ServiceProfile.Var
If ($tmp1 -ne $null)
{
    For ($i=0; $i -lt $objectTable.length; $i++)
    {
        $obj = $objectTable[$i]
        If ($obj[0] -eq 'ServiceProfile') {$obj[1] = 1; Break}
    }
}

##########
# Display to operator which objects do not have any defined values
$tmp = $false
For ($i=0; $i -lt $objectTable.length; $i++)
{
    $obj = $objectTable[$i]
    If ($obj[1] -eq '0')
    {
        $tmp1 = $obj[0]
        Write-Host "No defined values for object $tmp1"
        $tmp = $true
    }
}

##########
# Test for Validation errors or Validate only run.  If found, wrap up and shut down.
If ($errTag -or $validateOnly)
{
    If ($errTag)
    {
        Write-Host -ForegroundColor Red -BackgroundColor Black "`n`nProcessing stopped due to detected errors"
    }
    Set-Location $originalPath
    $endTime = Get-Date
    $elapsedTime = New-TimeSpan $startTime $endTime
    Write-Host -ForegroundColor Yellow -BackgroundColor Black "`n`n-----------------------------------------------------------`n"
    Write-Log "Elapsed time: $($elapsedTime.Hours):$($elapsedTime.Minutes):$($elapsedTime.Seconds)" "Normal"
    Write-Log "End of processing." "Normal"
    Exit
}

##########
# Missing values is not necessarily an error.  Ask if operator wishes to continue.
If ($tmp)
{
    Write-Host "`nYou have some missing values.  Do you wish to continue without them?"
    $tmp1 = Read-Host "You must enter 'YES' (no quotes) to continue"
    If ($tmp1 -ne 'YES') {Exit}
}

################################################################################
################################################################################
# ------------------------------------------------------------------------------
#
# Configure UCS with the contents of UcsConfig.XML
#
# ------------------------------------------------------------------------------
################################################################################

# Login to UCSM IP address
$ucsmIP = $UcsConfig.VSPEX.UCSMIP.trim()
$Error.Clear()
Write-Host -BackgroundColor Black -ForegroundColor White "`n`n    Enter proper credentials to access UCSM`n"
$ucsCreds = Get-Credential
$ucsHandle = Connect-Ucs $ucsmIP $ucsCreds
$ucsDomain = $ucsHandle.Ucs
If ($error.length -lt 1)
{
    Write-Log "Successful login to UCS domain $ucsDomain" "Normal"
}
Else
{
    Write-Log "Invalid login to $ucsmIP" "Error"
    exit
}
$orgRoot = Get-UcsOrg -Level root

##########
# Set timezone
$present = $false
For ($i=0; $i -lt $objectTable.length; $i++)
{
    $obj = $objectTable[$i]
    If ($obj[0] -eq 'TimeZone' -and $obj[1] -eq '1') {$present = $true; Break}
}
If ($Present)
{
    $error.Clear()
    $tmp1 = $ucsConfig.VSPEX.TimeZone.trimend(" ")
    $trash = Get-UcsTimezone | Set-UcsTimezone -AdminState "enabled" -Timezone $tmp1 -Force
    If ($error.length -lt 1)
    {
        Write-Log "Set timezone to $tmp1" "Normal"
    }
    Else
    {
        Write-Log "ERROR setting timezone to $tmp1" "Error"
        $errTag = $True
    }
}

##########
# Set NTP servers
$present = $false
For ($i=0; $i -lt $objectTable.length; $i++)
{
    $obj = $objectTable[$i]
    If ($obj[0] -eq 'NTP' -and $obj[1] -eq '1') {$present = $true; Break}
}
If ($Present)
{
    $ucsConfig.VSPEX.NTP | ForEach-Object {$_.Var} | ForEach-Object {
        $error.Clear()
        $tmp1 = $_.Name.trim()
        $trash = Add-UcsNtpServer -Name $tmp1 -ModifyPresent
        If ($error.length -lt 1)
        {
            Write-Log "Set NTP server to $tmp1" "Normal"
        }
        Else
        {
            Write-Log "ERROR setting NTP server to $tmp1" "Error"
            $errTag = $True
        }
    }
}

##########
# Set Management IP Pool values
$present = $false
For ($i=0; $i -lt $objectTable.length; $i++)
{
    $obj = $objectTable[$i]
    If ($obj[0] -eq 'MgmtIP' -and $obj[1] -eq '1') {$present = $true; Break}
}
If ($Present)
{
    $ucsConfig.VSPEX.MgmtIP | ForEach-Object {$_.Pool} | ForEach-Object {
        $error.Clear()
        $tmp1 = $_
        $tmp2 = $_.Name.trim()
        $tmp3 = $_.Descr
        $tmp1 | ForEach-Object {
            $tmp = $False
            $tmp4 = $_.Order.trim()
            $tmp5 = $_.Start.trim()
            $tmp6 = $_.End.trim()
            $tmp7 = $_.Gateway.trim()
            $tmp8 = $_.PrimaryDNS.trim()
            $tmp9 = $_.SecondaryDNS.trim()

            Start-UcsTransaction
              $mo = $orgRoot | Add-UcsIpPool -Name $tmp2 -Descr $tmp3 -AssignmentOrder $tmp4 -ModifyPresent
              $trash =$mo | Add-UcsIpPoolBlock -From $tmp5 -To $tmp6 -DefGw $tmp7 -PrimDns $tmp8 -SecDns $tmp9 -ModifyPresent
            Complete-UcsTransaction | Out-Null

            If ($error.length -lt 1)
            {
                Write-Log "Management IP Pool - Name=$tmp2 Descr=$tmp3 Order=$tmp4" "Normal"
                Write-Log "                   - From=$tmp5 To=$tmp6 G/W=$tmp7 Primary=$tmp8 Secondary=$tmp9" "Normal"
            }
            Else
            {
                Write-Log "ERROR Management IP Pool - Name=$tmp2 Descr=$tmp9 Order=$tmp3" "Error"
                Write-Log "                         - From=$tmp4 To=$tmp5 G/W=$tmp6 Primary=$tmp7 Secondary=$tmp8" "Error"
                $errTag = $True
            }

        }
    }
}

##########
# Set Call Home values
$present = $false
For ($i=0; $i -lt $objectTable.length; $i++)
{
    $obj = $objectTable[$i]
    If ($obj[0] -eq 'CallHome' -and $obj[1] -eq '1') {$present = $true; Break}
}
If ($Present)
{
    $error.Clear()
    $tmp1 = $ucsConfig.VSPEX.CallHome.InUse.trim()
    If ($tmp1 -eq '1')
    {
        $tmp1 = $ucsConfig.VSPEX.CallHome.SmtpSrv.trimend(" ")
        $tmp2 = $ucsConfig.VSPEX.CallHome.Address.trimend(" ")
        $tmp3 = $ucsConfig.VSPEX.CallHome.ContactName.trimend(" ")
        $tmp4 = $ucsConfig.VSPEX.CallHome.ContactPhone.trimend(" ")
        $tmp5 = $ucsConfig.VSPEX.CallHome.ContactEmail.trimend(" ")
        $tmp6 = $ucsConfig.VSPEX.CallHome.CustomerID.trimend(" ")
        $tmp7 = $ucsConfig.VSPEX.CallHome.ContractID.trimend(" ")
        $tmp8 = $ucsConfig.VSPEX.CallHome.SiteID.trimend(" ")
        $tmp9 = $ucsConfig.VSPEX.CallHome.SmtpFrom.trimend(" ")
        $tmp10 = $ucsConfig.VSPEX.CallHome.SmtpRecipient.trimend(" ")
        Start-UcsTransaction
          $trash = Get-UcsCallhome | Set-UcsCallhome -AdminState on -AlertThrottlingAdminState on -Force
          $trash = Get-UcsCallhomeSmtp | Set-UcsCallhomeSmtp -Host $tmp1 -Port 25 -Force
          $trash = Get-UcsCallhomeSource | Set-UcsCallhomeSource -Addr $tmp2 -Contact $tmp3 -Email $tmp5 -Contract $tmp7 -Customer $tmp6 `
              -From $tmp9 -Phone $tmp4 -ReplyTo $tmp9 -Site $tmp8 -Urgency debug -Force
          $trash = Get-UcsCallhomeProfile -Name full_txt | Add-UcsCallhomeRecipient -Email $tmp10 -ModifyPresent
        Complete-UcsTransaction | Out-Null
        If ($error.length -lt 1)
        {
            Write-Log "Set call home for $tmp3" "Normal"
        }
        Else
        {
            Write-Log "ERROR setting call home for $tmp3" "Error"
            $errTag = $True
        }
    }
}

##########
# Set Chassis discovery setting
$present = $false
For ($i=0; $i -lt $objectTable.length; $i++)
{
    $obj = $objectTable[$i]
    If ($obj[0] -eq 'ChassisDiscovery' -and $obj[1] -eq '1') {$present = $true; Break}
}
If ($Present)
{
    $error.Clear()
    $tmp1 = $ucsConfig.VSPEX.ChassisDiscovery.trim()
    $trash = $orgRoot | Get-UcsChassisDiscoveryPolicy | Set-UcsChassisDiscoveryPolicy -Action $tmp1 `
        -LinkAggregationPref "port-channel" -Rebalance "user-acknowledged" -Force
    If ($error.length -lt 1)
    {
        Write-Log "Set chassis discovery policy to $tmp1" "Normal"
    }
    Else
    {
        Write-Log "ERROR setting chassis discovery policy to $tmp1" "Error"
        $errTag = $True
    }

##########
# Set Number of Chassis
    $tmp1 = Get-UcsChassis
    ForEach ($chassis in $tmp1)
    {
        $error.Clear()
        $tmp2 = $chassis.ID
        $trash = Get-UcsChassis -Id $tmp2 | Set-UcsChassis -AdminState "re-acknowledge" -Force
        If ($error.length -lt 1)
        {
            Write-Log "Chassis $tmp2 acknowledged" "Normal"
        }
        Else
        {
            Write-Log "ERROR acknowledging chassis $tmp2" "Error"
            $errTag = $True
        }
    }
}

##########
# Set Organizations
$present = $false
For ($i=0; $i -lt $objectTable.length; $i++)
{
    $obj = $objectTable[$i]
    If ($obj[0] -eq 'SubOrg' -and $obj[1] -eq '1') {$present = $true; Break}
}
If ($Present)
{
    $ucsConfig.VSPEX.SubOrg | ForEach-Object {$_.Var} | ForEach-Object {
        $error.Clear()
        $tmp1 = $_.Name
        $tmp2 = $_.Descr
        $trash = $orgRoot  | Add-UcsOrg -Name $tmp1 -Descr $tmp2 -ModifyPresent
        If ($error.length -lt 1)
        {
            Write-Log "Set organization Name=$tmp1 Description=$tmp2" "Normal"
        }
        Else
        {
            Write-Log "ERROR setting organization Name=$tmp1 Description=$tmp2" "Error"
            $errTag = $True
        }
    }
}

##########
# Set QoS Policies
$error.Clear()
$trash = Get-UcsBestEffortQosClass | Set-UcsBestEffortQosClass -Mtu "9000" -Force | Out-Null
If ($error.length -lt 1)
{
    Write-Log "Set Best Effort QoS Class to MTU=9000" "Normal"
}
Else
{
    Write-Log "ERROR setting Best Effort QoS Class to MTU=9000" "Error"
    $errTag = $True
}

$present = $false
For ($i=0; $i -lt $objectTable.length; $i++)
{
    $obj = $objectTable[$i]
    If ($obj[0] -eq 'QoS' -and $obj[1] -eq '1') {$present = $true; Break}
}
If ($Present)
{

     # Platinum
    $error.Clear()
    $tmp1 = $ucsConfig.VSPEX.QoS.Platinum.trim()
    If ($tmp1 -ne "")
    {
          $trash = Get-UcsQosClass -Priority "platinum" | Set-UcsQosClass -Mtu "9000" -Force
          $mo = Add-UcsQosPolicy –Name $tmp1 -ModifyPresent
          $trash = $mo | Get-UcsVnicEgressPolicy | Set-UcsVnicEgressPolicy -Prio "platinum" -Force
        If ($error.length -lt 1)
        {
            Write-Log "Set platinum QoS Class to MTU=9000" "Normal"
        }
        Else
        {
            Write-Log "ERROR setting platinum QoS Class to MTU=9000" "Error"
            $errTag = $True
        }
    }

     # Gold
    $error.Clear()
    $tmp1 = $ucsConfig.VSPEX.QoS.Gold.trim()
    If ($tmp1 -ne "")
    {
          $trash = Get-UcsQosClass -Priority "gold" | Set-UcsQosClass -Mtu "9000" -Force
          $mo = Add-UcsQosPolicy –Name $tmp1 -ModifyPresent
          $trash = $mo | Get-UcsVnicEgressPolicy | Set-UcsVnicEgressPolicy -Prio "gold" -Force
        If ($error.length -lt 1)
        {
            Write-Log "Set gold QoS Class to MTU=9000" "Normal"
        }
        Else
        {
            Write-Log "ERROR setting gold QoS Class to MTU=9000" "Error"
            $errTag = $True
        }
    }

     # Silver
    $error.Clear()
    $tmp1 = $ucsConfig.VSPEX.QoS.Silver.trim()
    If ($tmp1 -ne "")
    {
          $trash = Get-UcsQosClass -Priority "silver" | Set-UcsQosClass -Mtu "9000" -Force
          $mo = Add-UcsQosPolicy –Name $tmp1 -ModifyPresent
          $trash = $mo | Get-UcsVnicEgressPolicy | Set-UcsVnicEgressPolicy -Prio silver -Force
        If ($error.length -lt 1)
        {
            Write-Log "Set silver QoS Class to MTU=9000" "Normal"
        }
        Else
        {
            Write-Log "ERROR setting silver QoS Class to MTU=9000" "Error"
            $errTag = $True
        }
    }

     # Bronze
    $error.Clear()
    $tmp1 = $ucsConfig.VSPEX.QoS.Bronze.trim()
    If ($tmp1 -ne "")
    {
          $trash = Get-UcsQosClass -Priority "bronze" | Set-UcsQosClass -Mtu "9000" -Force
          $mo = Add-UcsQosPolicy –Name $tmp1 -ModifyPresent
          $trash = $mo | Get-UcsVnicEgressPolicy | Set-UcsVnicEgressPolicy -Prio bronze -Force
    If ($error.length -lt 1)
        {
            Write-Log "Set bronze QoS Class to MTU=9000" "Normal"
        }
        Else
        {
            Write-Log "ERROR setting bronze QoS Class to MTU=9000" "Error"
            $errTag = $True
        }
    }

}

##########
# Set Power Control Policies
$present = $false
For ($i=0; $i -lt $objectTable.length; $i++)
{
    $obj = $objectTable[$i]
    If ($obj[0] -eq 'PowerPolicy' -and $obj[1] -eq '1') {$present = $true; Break}
}
If ($Present)
{
    $ucsConfig.VSPEX.PowerPolicy | ForEach-Object {$_.Var} | ForEach-Object {
        $error.Clear()
        $tmp1 = $_.Name.trim()
        $tmp2 = $_.Priority.trim()
        If ($tmp1 -eq 'Default') {$tmp1 = $tmp1.tolower()}
        $trash = $orgRoot | Add-UcsPowerPolicy -Name $tmp1 -Prio $tmp2 -ModifyPresent
        If ($error.length -lt 1)
        {
            Write-Log "Set power control policy Name=$tmp1 to Priority=$tmp2" "Normal"
        }
        Else
        {
            Write-Log "ERROR setting power control policy Name=$tmp1 to Priority=$tmp2" "Error"
            $errTag = $True
        }
    }
}

##########
# Set Scrub Policies
$present = $false
For ($i=0; $i -lt $objectTable.length; $i++)
{
    $obj = $objectTable[$i]
    If ($obj[0] -eq 'ScrubPolicy' -and $obj[1] -eq '1') {$present = $true; Break}
}
If ($Present)
{
    $ucsConfig.VSPEX.ScrubPolicy | ForEach-Object {$_.Var} | ForEach-Object {
        $error.Clear()
        $tmp1 = $_.Name.trim()
        $tmp2 = $_.Descr
        $tmp3 = $_.DiskScrub.trim()
        $tmp3 = $tmp3.tolower()
        $tmp4 = $_.BiosScrub.trim()
        $tmp4 = $tmp4.tolower()
        If ($tmp1 -eq 'Default') {$tmp1 = $tmp1.tolower()}
        $trash = $orgRoot  | Add-UcsScrubPolicy -Name $tmp1 -Descr $tmp2 -DiskScrub $tmp3 -BiosSettingsScrub $tmp4 -PolicyOwner "local" -ModifyPresent
        If ($error.length -lt 1)
        {
            Write-Log "Set scrub policy Name=$tmp1 Desc=$tmp2 Disc=$tmp3 Bios=$tmp4" "Normal"
        }
        Else
        {
            Write-Log "ERROR setting scrub policy Name=$tmp1 Desc=$tmp2 Disc=$tmp3 Bios=$tmp4" "Error"
            $errTag = $True
        }
    }
}

##########
# Set Maintenance Policies
$present = $false
For ($i=0; $i -lt $objectTable.length; $i++)
{
    $obj = $objectTable[$i]
    If ($obj[0] -eq 'MaintenancePolicy' -and $obj[1] -eq '1') {$present = $true; Break}
}
If ($Present)
{
    $ucsConfig.VSPEX.MaintenancePolicy | ForEach-Object {$_.Var} | ForEach-Object {
        $error.Clear()
        $tmp1 = $_.Name.trim()
        $tmp2 = $_.Descr.trim()
        $tmp3 = $_.Policy.trim()
        $tmp3 = $tmp3.tolower()
        $trash = $orgRoot  | Add-UcsMaintenancePolicy -Name $tmp1 -Descr $tmp2 -UptimeDisr $tmp3 -ModifyPresent
        If ($error.length -lt 1)
        {
            Write-Log "Set maintenance policy Name=$tmp1 Descr=$tmp2 Policy=$tmp3" "Normal"
        }
        Else
        {
            Write-Log "ERROR setting maintenance policy Name=$tmp1 Descr=$tmp2 Policy=$tmp3" "Error"
            $errTag = $True
        }
    } 
}

##########
# Set Local Disk Policies
$present = $false
For ($i=0; $i -lt $objectTable.length; $i++)
{
    $obj = $objectTable[$i]
    If ($obj[0] -eq 'DiskPolicy' -and $obj[1] -eq '1') {$present = $true; Break}
}
If ($Present)
{
#Set-UcsQosClass –QosClass (Get-UcsQosClass –Priority gold) –AdminState enabled –Mtu 9000 -Force
    $ucsConfig.VSPEX.DiskPolicy | ForEach-Object {$_.Var} | ForEach-Object {
        $error.Clear()
        $tmp1 = $_.Name.trim()
        $tmp2 = $_.Mode.trim()
        $tmp2 = $tmp2.tolower()
        $tmp3 = $_.Descr.trim()
        $tmp4 = $_.Protect.trim()
        $tmp4 = $tmp4.tolower()
        $trash = $orgRoot | Add-UcsLocalDiskConfigPolicy -Name $tmp1 -Mode $tmp2 -Descr $tmp3 -ProtectConfig $tmp4 -ModifyPresent
        If ($error.length -lt 1)
        {
            Write-Log "Set Local Disk Config Policy Name=$tmp1 Mode=$tmp2 Descr=$tmp3 Protect=$tmp4" "Normal"
        }
        Else
        {
            Write-Log "ERROR setting Local Disk Config Policy Name=$tmp1 Mode=$tmp2 Descr=$tmp3 Protect=$tmp4" "Error"
            $errTag = $True
        }
    }
}

##########
# Set BIOS Policy
$present = $false
For ($i=0; $i -lt $objectTable.length; $i++)
{
    $obj = $objectTable[$i]
    If ($obj[0] -eq 'BIOSPolicy' -and $obj[1] -eq '1') {$present = $true; Break}
}
If ($Present)
{
    $ucsConfig.VSPEX.BIOSPolicy | ForEach-Object {$_.Var} | ForEach-Object {
        $error.Clear()
        $tmp1 = $_.Name.trim()
        $tmp2 = $_.Descr
        $tmp3 = $_.VpQuietBoot.trim()
        Start-UcsTransaction
          $mo = $orgRoot  | Add-UcsBiosPolicy -Name $tmp1 -Descr $tmp2 -RebootOnUpdate "no" -ModifyPresent
          $mo | Set-UcsBiosVfQuietBoot -VpQuietBoot $tmp3 -Force | Out-Null
        Complete-UcsTransaction | Out-Null
        If ($error.length -lt 1)
        {
            Write-Log "Create BIOS Policy - Name=$tmp1 Descr=$tmp2 QuietBoot=$tmp3" "Normal"
        }
        Else
        {
            Write-Log "ERROR create BIOS Policy - Name=$tmp1 Descr=$tmp2 QuietBoot=$tmp3" "Error"
            $errTag = $True
        }
    }
}

##########
# Set vNIC/vHBA Placement Policy
$present = $false
For ($i=0; $i -lt $objectTable.length; $i++)
{
    $obj = $objectTable[$i]
    If ($obj[0] -eq 'PlacementPolicy' -and $obj[1] -eq '1') {$present = $true; Break}
}
If ($Present)
{
    $ucsConfig.VSPEX.PlacementPolicy | ForEach-Object {$_.Var} | ForEach-Object {
        $error.Clear()
        $tmp1 = $_.Name.trim()
        $tmp2 = $_.SlotMapping.trim()
        $tmp3 = $_.Selection.trim()
        Start-UcsTransaction
          $mo = $orgRoot  | Add-UcsPlacementPolicy -Name $tmp1 -MezzMapping $tmp2 -ModifyPresent
          $trash = $mo | Add-UcsFabricVCon -Fabric "NONE" -Id "1" -Select $tmp3 -Share "shared" -Transport "ethernet","fc" -ModifyPresent
          $trash = $mo | Add-UcsFabricVCon -Fabric "NONE" -Id "2" -InstType "auto" -Placement "physical" -Select "all" -Share "shared" -Transport "ethernet","fc" -ModifyPresent
          $trash = $mo | Add-UcsFabricVCon -Fabric "NONE" -Id "3" -InstType "auto" -Placement "physical" -Select "all" -Share "shared" -Transport "ethernet","fc" -ModifyPresent
          $trash = $mo | Add-UcsFabricVCon -Fabric "NONE" -Id "4" -InstType "auto" -Placement "physical" -Select "all" -Share "shared" -Transport "ethernet","fc" -ModifyPresent
        Complete-UcsTransaction | Out-Null
        If ($error.length -lt 1)
        {
            Write-Log "Create vNIC/vHBA Placement Policy - Name=$tmp1 Mapping=$tmp2 Selection=$tmp3" "Normal"
        }
        Else
        {
            Write-Log "ERROR creating vNIC/vHBA Placement Policy - Name=$tmp1 Mapping=$tmp2 Selection=$tmp3" "Error"
            $errTag = $True
        }
    }
}

##########
# FI port definitions - assumption that both fabrics are configured identically
$present = $false
For ($i=0; $i -lt $objectTable.length; $i++)
{
    $obj = $objectTable[$i]
    If ($obj[0] -eq 'FI' -and $obj[1] -eq '1') {$present = $true; Break}
}
If ($Present)
{
    $ucsConfig.VSPEX.FI | ForEach-Object {$_.Var} | ForEach-Object {
        $error.Clear()
        $tmp1 = $_.SlotID.trim()
        $tmp2 = $_.PortID.trim()
        $tmp3 = $_.Role.trim()
        $tmp4 = $_.UsrLbl
        $tmp5 = $_.VLAN.trim()
        $tmp6 = $_.Native.trim()
        $tmp6 = $tmp6.tolower()
        $tmp7 = $_.Mode.trim()
        $tmp7 = $tmp7.tolower()
        $tmp8 = $_.QoS.trim()
        $tmp8 = $tmp8.tolower()

        If ($tmp3 -ne '')
        {
            Switch ($tmp3)
            {
                Appliance
                {
                    Start-UcsTransaction
                      $trash = Get-UcsApplianceCloud | Get-UcsVlan -Name $tmp5 -LimitScope | Add-UcsVlanMemberPort -SwitchId "A" -SlotId $tmp1 `
                          -PortId $tmp2 -AdminState "enabled" -IsNative $tmp6 -Name "" -ModifyPresent
                      $trash = Get-UcsFabricApplianceCloud -Id "A" | Add-UcsAppliancePort -Slot $tmp1 -PortId $tmp2 -PortMode $tmp7 -Prio $tmp8 `
                          -UsrLbl $tmp4 -AdminSpeed "10gbps" -AdminState "enabled" -FlowCtrlPolicy "default" -Name "" -NwCtrlPolicyName "default" `
                          -PinGroupName "" -ModifyPresent
                      $trash = Get-UcsApplianceCloud | Get-UcsVlan -Name $tmp5 -LimitScope | Add-UcsVlanMemberPort -SwitchId "B" -SlotId $tmp1 `
                          -PortId $tmp2 -AdminState "enabled" -IsNative $tmp6 -Name "" -ModifyPresent
                      $trash = Get-UcsFabricApplianceCloud -Id "B" | Add-UcsAppliancePort -SlotId $tmp1 -PortId $tmp2 -PortMode $tmp7 -Prio $tmp8 `
                          -UsrLbl $tmp4 -AdminSpeed "10gbps" -AdminState "enabled" -FlowCtrlPolicy "default" -Name "" -NwCtrlPolicyName "default" `
                          -PinGroupName "" -ModifyPresent
                    Complete-UcsTransaction | Out-Null
                    If ($error.length -lt 1)
                    {
                        Write-Log "Set fabric port - Slot=$tmp1 Port=$tmp2 Role=$tmp3 UsrLbl=$tmp4" "Normal"
                        Write-Log "                - VLAN=$tmp5 Native=$tmp6 Mode=$tmp7 QoS=$tmp8" "Normal"
                    }
                    Else
                    {
                        Write-Log "ERROR setting fabric port - Slot=$tmp1 Port=$tmp2 Role=$tmp3 UsrLbl=$tmp4" "Error"
                        Write-Log "                          - VLAN=$tmp5 Native=$tmp6 Mode=$tmp7 QoS=$tmp8" "Error"
                        $errTag = $True
                    }
                }
                FCoE
                {
                    $trash = Get-UcsFiSanCloud -Id "A" | Add-UcsFabricFcoeSanEp -SlotId $tmp1 -PortId $tmp2 -UsrLbl $tmp4 -Name "" `
                        -AdminState "enabled" -ModifyPresent
                    $trash = Get-UcsFiSanCloud -Id "B" | Add-UcsFabricFcoeSanEp -SlotId $tmp1 -PortID $tmp2 -UsrLbl $tmp4 -Name "" `
                        -AdminState "enabled" -ModifyPresent
                    If ($error.length -lt 1)
                    {
                        Write-Log "Set fabric port - Slot=$tmp1 Port=$tmp2 Role=$tmp3 UsrLbl=$tmp4" "Normal"
                    }
                    Else
                    {
                        Write-Log "ERROR setting fabric port - Slot=$tmp1 Port=$tmp2 Role=$tmp3 UsrLbl=$tmp4" "Error"
                        $errTag = $True
                    }
                }
                Server
                {
                    $trash = Get-UcsFabricServerCloud -Id "A" | Add-UcsServerPort -SlotId $tmp1 -PortId $tmp2 -UsrLbl $tmp4 -Name "" `
                        -AdminState "enabled" -ModifyPresent
                    $trash = Get-UcsFabricServerCloud -Id "B" | Add-UcsServerPort -SlotId $tmp1 -PortId $tmp2 -UsrLbl $tmp4 -Name "" `
                        -AdminState "enabled" -ModifyPresent
                    If ($error.length -lt 1)
                    {
                        Write-Log "Set fabric port - Slot=$tmp1 Port=$tmp2 Role=$tmp3 UsrLbl=$tmp4" "Normal"
                    }
                    Else
                    {
                        Write-Log "ERROR setting fabric port - Slot=$tmp1 Port=$tmp2 Role=$tmp3 UsrLbl=$tmp4" "Error"
                        $errTag = $True
                    }
                }
                Uplink
                {
                    $trash = Get-UcsFiLanCloud -Id "A" | Add-UcsUplinkPort -SlotId $tmp1 -PortId $tmp2 -UsrLbl $tmp4 -Name "" `
                        -AdminSpeed "10gbps" -AdminState "enabled" -FlowCtrlPolicy "default" -ModifyPresent
                    $trash = Get-UcsFiLanCloud -Id "B" | Add-UcsUplinkPort -SlotId $tmp1 -PortId $tmp2 -UsrLbl $tmp4 -Name "" `
                        -AdminSpeed "10gbps" -AdminState "enabled" -FlowCtrlPolicy "default" -ModifyPresent
                    If ($error.length -lt 1)
                    {
                        Write-Log "Set fabric port - Slot=$tmp1 Port=$tmp2 Role=$tmp3 UsrLbl=$tmp4" "Normal"
                    }
                    Else
                    {
                        Write-Log "ERROR setting fabric port - Slot=$tmp1 Port=$tmp2 Role=$tmp3 UsrLbl=$tmp4" "Error"
                        $errTag = $True
                    }
                }
            }
        }
    }
}

##########
# Fibre Channel Port definition
$fiA = Get-UcsFiSanCloud -Id "A"
$fiB = Get-UcsFiSanCloud -Id "B"

$present = $false
For ($i=0; $i -lt $objectTable.length; $i++)
{
    $obj = $objectTable[$i]
    If ($obj[0] -eq 'FCslot1' -and $obj[1] -eq '1') {$present = $true; Break}
}
If ($Present)
{
    [int]$itmp1 = $ucsConfig.VSPEX.FCslot1.PortID
    If ($itmp1 -ne 0)
    {
        $error.Clear()
        $tmp2 = $ucsConfig.VSPEX.FCslot1.UsrLbl
        Start-UcsTransaction
          For ($i=32; $i -ge $itmp1; $i--)
          {
              $trash = $fiA | Add-UcsFcUplinkPort -SlotId 1 -PortId $i -UsrLbl $tmp2 -AdminState "enabled" -Name "" -ModifyPresent
          }
        Complete-UcsTransaction | Out-Null
        Start-UcsTransaction
          For ($i=32; $i -ge $itmp1; $i--)
          {
              $trash = $fiB | Add-UcsFcUplinkPort -SlotId 1 -PortId $i -UsrLbl $tmp2 -AdminState "enabled" -Name "" -ModifyPresent
          }
        Complete-UcsTransaction | Out-Null

        If ($error.length -lt 1)
        {
            Write-Log "Set Fixed Module FC Port - Port=$itmp1 UsrLbl=$tmp2" "Normal"
        }
        Else
        {
            Write-Log "ERROR setting Fixed Module FC Port - Port=$itmp1 UsrLbl=$tmp2" "Error"
            $errTag = $True
        }
    }
}

$present = $false
For ($i=0; $i -lt $objectTable.length; $i++)
{
    $obj = $objectTable[$i]
    If ($obj[0] -eq 'FCslot2' -and $obj[1] -eq '1') {$present = $true; Break}
}
If ($Present)
{
    [int]$itmp1 = $ucsConfig.VSPEX.FCslot2.PortID
    If ($itmp1 -ne 0)
    {
        $error.Clear()
        $tmp2 = $ucsConfig.VSPEX.FCslot2.UsrLbl
        Start-UcsTransaction
          For ($i=16; $i -ge $itmp1; $i--)
          {
              $trash = $fiA | Add-UcsFcUplinkPort -SlotId 2 -PortId $i -UsrLbl $tmp2 -AdminState "enabled" -Name "" -ModifyPresent
          }
        Complete-UcsTransaction | Out-Null
        Start-UcsTransaction
          For ($i=16; $i -ge $itmp1; $i--)
          {
              $trash = $fiB | Add-UcsFcUplinkPort -SlotId 2 -PortId $i -UsrLbl $tmp2 -AdminState "enabled" -Name "" -ModifyPresent
          }
        Complete-UcsTransaction | Out-Null

        If ($error.length -lt 1)
        {
            Write-Log "Set Expansion Module FC Port - Port=$itmp1 UsrLbl=$tmp2" "Normal"
        }
        Else
        {
            Write-Log "ERROR setting Expansion Module FC Port - Port=$itmp1 UsrLbl=$tmp2" "Error"
            $errTag = $True
        }
    }
}

##########
# Port Channel
$present = $false
For ($i=0; $i -lt $objectTable.length; $i++)
{
    $obj = $objectTable[$i]
    If ($obj[0] -eq 'PC' -and $obj[1] -eq '1') {$present = $true; Break}
}
If ($Present)
{
    $tmp1 = $ucsConfig.VSPEX.PC.AName.trim()
    $tmp2 = $ucsConfig.VSPEX.PC.BName.trim()
    $tmp3 = $ucsConfig.VSPEX.PC.APortID.trim()
    $tmp4 = $ucsConfig.VSPEX.PC.BPortID.trim()
    $tmp5 = $ucsConfig.VSPEX.PC.Slot.trim()
    $tmp6 = $ucsConfig.VSPEX.PC.Port1.trim()
    $tmp7 = $ucsConfig.VSPEX.PC.Port2.trim()

    $error.Clear()
    Start-UcsTransaction
      $mo = Get-UcsFiLanCloud –Id A | Add-UcsUplinkPortChannel -Name $tmp1 -PortId $tmp3 `
          –AdminState "enabled" -AdminSpeed "10gbps" -FlowCtrlPolicy "default" -ModifyPresent
      $trash = $mo | Add-UcsUplinkPortChannelMember -SlotId $tmp5 -PortId $tmp6 –AdminState "enabled" -ModifyPresent
      $trash = $mo | Add-UcsUplinkPortChannelMember -SlotId $tmp5 -PortId $tmp7 –AdminState "enabled" -ModifyPresent
    Complete-UcsTransaction | Out-Null
    If ($error.length -lt 1)
    {
        Write-Log "Set Port Channel - Name=$tmp1 PortChannelID=$tmp3 Slot/Port/Port=$tmp5/$tmp6/$tmp7" "Normal"
    }
    Else
    {
        Write-Log "ERROR Set Port Channel - Name=$tmp1 PortChannelID=$tmp3 Slot/Port/Port=$tmp5/$tmp6/$tmp7" "Error"
        $errTag = $True
    }

    $error.Clear()
    Start-UcsTransaction
      $mo = Get-UcsFiLanCloud –Id B | Add-UcsUplinkPortChannel –Name $tmp2 -PortId $tmp4 `
          –AdminState "enabled" -AdminSpeed "10gbps" -FlowCtrlPolicy "default" -ModifyPresent
      $trash = $mo | Add-UcsUplinkPortChannelMember -SlotId $tmp5 -PortId $tmp6 –AdminState "enabled" -ModifyPresent
      $trash = $mo | Add-UcsUplinkPortChannelMember -SlotId $tmp5 -PortId $tmp7 –AdminState "enabled" -ModifyPresent
    Complete-UcsTransaction | Out-Null
    If ($error.length -lt 1)
    {
        Write-Log "Set Port Channel - Name=$tmp2 PortChannelID=$tmp4 Slot/Port/Port=$tmp5/$tmp6/$tmp7" "Normal"
    }
    Else
    {
        Write-Log "ERROR Set Port Channel - Name=$tmp2 PortChannelID=$tmp4 Slot/Port/Port=$tmp5/$tmp6/$tmp7" "Error"
        $errTag = $True
    }
}

##########
# Various Pools
$present = $false
For ($i=0; $i -lt $objectTable.length; $i++)
{
    $obj = $objectTable[$i]
    If ($obj[0] -eq 'Pools' -and $obj[1] -eq '1') {$present = $true; Break}
}
If ($Present)
{
    $ucsConfig.VSPEX.Pools | ForEach-Object {$_.Var} | ForEach-Object {
        $error.Clear()
        $tmp1 = $_.Type.trim()
        $tmp2 = $_.Name.trim()
        $tmp3 = $_.From.trim()
        $tmp4 = $_.To.trim()
        $tmp5 = $_.Order.trim()
        $tmp5 = $tmp5.tolower()
        $tmp6 = $_.Org.trim()
        $tmp7 = $_.Descr
        If ($tmp2 -eq 'default') {$tmp2 = $tmp2.tolower()}

        If ($tmp6 -eq "root") {$mo = $orgRoot}
        Else {$mo = $orgRoot | Get-UcsOrg -Name $tmp6 -LimitScope}
        Switch ($tmp1)
        {
            MAC
            {
                Start-UcsTransaction
                  $mo_1 = $mo | Add-UcsMacPool -Name $tmp2 -AssignmentOrder $tmp5 -Descr $tmp7 -ModifyPresent
                  $trash = $mo_1 | Add-UcsMacMemberBlock -From $tmp3 -To $tmp4 -ModifyPresent
                Complete-UcsTransaction | Out-Null
                If ($error.length -lt 1)
                {
                    Write-Log "Add MAC Pool - Name=$tmp2 Org=$tmp6 Descr=$tmp7 From/To=$tmp3-$tmp4" "Normal"
                }
                Else
                {
                    Write-Log "ERROR Add MAC Pool - Name=$tmp2 Org=$tmp6 Descr=$tmp7 From/To=$tmp3-$tmp4" "Error"
                    $errTag = $True
                }
            }
            UUID
            {
                Start-UcsTransaction
                  $mo_1 = $mo | Add-UcsUuidSuffixPool –Name $tmp2 -AssignmentOrder $tmp5 -Descr $tmp7  -ModifyPresent
                  $trash = $mo_1 | Add-UcsUuidSuffixBlock -From $tmp3 -To $tmp4 -ModifyPresent
                Complete-UcsTransaction | Out-Null
                If ($error.length -lt 1)
                {
                    Write-Log "Add UUID Pool - Name=$tmp2 Org=$tmp6 Descr=$tmp7 From/To=$tmp3-$tmp4" "Normal"
                }
                Else
                {
                    Write-Log "ERROR Add UUID Pool - Name=$tmp2 Org=$tmp6 Descr=$tmp7 From/To=$tmp3-$tmp4" "Error"
                    $errTag = $True
                }
            }
            WWNN
            {
                Start-UcsTransaction
                  $mo_1 = $mo | Add-UcsWwnPool -Name $tmp2 -AssignmentOrder $tmp5 -Purpose "node-wwn-assignment" -Descr $tmp7 -ModifyPresent
                  $trash = $mo_1 | Add-UcsWwnMemberBlock -From $tmp3 -To $tmp4 -ModifyPresent
                Complete-UcsTransaction | Out-Null
                If ($error.length -lt 1)
                {
                    Write-Log "Add WWNN Pool - Name=$tmp2 Org=$tmp6 Descr=$tmp7 From/To=$tmp3-$tmp4" "Normal"
                }
                Else
                {
                    Write-Log "ERROR Add WWNN Pool - Name=$tmp2 Org=$tmp6 Descr=$tmp7 From/To=$tmp3-$tmp4" "Error"
                    $errTag = $True
                }
            }
            WWPN
            {
                Start-UcsTransaction
                  $mo_1 = $mo | Add-UcsWwnPool -Name $tmp2 -AssignmentOrder $tmp5 -Purpose "port-wwn-assignment" -Descr $tmp7 -ModifyPresent
                  $trash = $mo_1 | Add-UcsWwnMemberBlock -From $tmp3 -To $tmp4 -ModifyPresent
                Complete-UcsTransaction | Out-Null
                If ($error.length -lt 1)
                {
                    Write-Log "Add WWPN Pool - Name=$tmp2 Org=$tmp6 Descr=$tmp7 From/To=$tmp3-$tmp4" "Normal"
                }
                Else
                {
                    Write-Log "ERROR Add WWPN Pool - Name=$tmp2 Org=$tmp6 Descr=$tmp7 From/To=$tmp3-$tmp4" "Error"
                    $errTag = $True
                }
            }
        }
    }
}

##########
# VLAN definitions
$present = $false
For ($i=0; $i -lt $objectTable.length; $i++)
{
    $obj = $objectTable[$i]
    If ($obj[0] -eq 'VLANs' -and $obj[1] -eq '1') {$present = $true; Break}
}
If ($Present)
{
    $ucsConfig.VSPEX.VLANs | ForEach-Object {$_.Var} | ForEach-Object {
        $error.Clear()
        $tmp1 = $_.Name.trim()
        $tmp2 = $_.Fabric.trim()
        $tmp3 = $_.ATag.trim()
        $tmp4 = $_.BTag.trim()
        $tmp5 = $_.DefaultNet.trim()
        Switch ($tmp2)
        {
            Common
            {
                $trash = Get-UcsLanCloud | Add-UcsVlan -Name $tmp1 -Id $tmp3 -DefaultNet $tmp5 -CompressionType "included" -Sharing "none" -ModifyPresent
            }
            Diff
            {
                $trash = Get-UcsFiLanCloud -Id "A" | Add-UcsVlan -Name $tmp1 -Id $tmp3 -DefaultNet $tmp5 -CompressionType "included" -Sharing "none" -ModifyPresent
                $trash = Get-UcsFiLanCloud -Id "B" | Add-UcsVlan -Name $tmp1 -Id $tmp4 -DefaultNet $tmp5 -CompressionType "included" -Sharing "none" -ModifyPresent
            }
            FabA
            {
                $trash = Get-UcsFiLanCloud -Id "A" | Add-UcsVlan -Name $tmp1 -Id $tmp3 -DefaultNet $tmp5 -CompressionType "included" -Sharing "none" -ModifyPresent
            }
            FabB
            {
                $trash = Get-UcsFiLanCloud -Id "B" | Add-UcsVlan -Name $tmp1 -Id $tmp4 -DefaultNet $tmp5 -CompressionType "included" -Sharing "none" -ModifyPresent
            }
        }
        If ($error.length -lt 1)
        {
            Write-Log "Add VLAN - Name=$tmp1 Fabric=$tmp2 ATag=$tmp3 BTag=$tmp4 DefaultNet=$tmp5" "Normal"
        }
        Else
        {
            Write-Log "ERROR Add VLAN - Name=$tmp1 Fabric=$tmp2 ATag=$tmp3 BTag=$tmp4 DefaultNet=$tmp5" "Error"
            $errTag = $True
        }
    }
}

##########
# VNIC Templates
$present = $false
For ($i=0; $i -lt $objectTable.length; $i++)
{
    $obj = $objectTable[$i]
    If ($obj[0] -eq 'VNICTemplate' -and $obj[1] -eq '1') {$present = $true; Break}
}
If ($Present)
{
    $ucsConfig.VSPEX.VNICTemplate | ForEach-Object {$_.Var} | ForEach-Object {
        $error.Clear()
        $tmp1 = $_.Name.trim()
        $tmp2 = $_.MTU.trim()
        $tmp3 = $_.Fabric.trim()
        $tmp3 = $tmp3.toupper()
        $tmp4 = $_.MACpool.trim()
        $tmp5 = $_.QoS.trim()
        $tmp6 = $_.VLAN.trim()
            $tmp7 = $_.Order.trim()
        $tmp8 = $_.Type.trim()
        $tmp8 = $tmp8.tolower()
        $tmp9 = $_.Native.trim()
        $tmp9 = $tmp9.tolower()
        $tmp10 = $_.Org.trim()

        If ($tmp10 -eq "root") {$org = $orgRoot}
        Else {$org = $orgRoot | Get-UcsOrg -Name $tmp10 -LimitScope}

        Start-UcsTransaction
          $mo = $org | Add-UcsVnicTemplate -Name $tmp1 -Mtu $tmp2 -SwitchId $tmp3 -IdentPoolName $tmp4 `
            -QosPolicyName $tmp5 -TemplType $tmp8 -ModifyPresent
          $trash = $mo | Add-UcsVnicInterface -Name $tmp6 -DefaultNet $tmp9 -ModifyPresent
        Complete-UcsTransaction | Out-Null
        If ($error.length -lt 1)
        {
            Write-Log "Add VNIC template - Name=$tmp1 MTU=$tmp2 Fabric=$tmp3 MACPool=$tmp4 Type=$tmp9" "Normal"
        }
        Else
        {
            Write-Log "ERROR Add VNIC template - Name=$tmp1 MTU=$tmp2 Fabric=$tmp3 MACPool=$tmp4 Type=$tmp9" "Error"
            $errTag = $True
        }
    }
}

##########
# vHBA Templates
$present = $false
For ($i=0; $i -lt $objectTable.length; $i++)
{
    $obj = $objectTable[$i]
    If ($obj[0] -eq 'VHBATemplate' -and $obj[1] -eq '1') {$present = $true; Break}
}
If ($Present)
{
    $ucsConfig.VSPEX.VHBATemplate | ForEach-Object {$_.Var} | ForEach-Object {
        $error.Clear()
        $tmp1 = $_.Name.trim()
        $tmp2 = $_.Descr
        $tmp3 = $_.Fabric.trim()
        $tmp3 = $tmp3.toupper()
        $tmp4 = $_.VSAN.trim()
        $tmp5 = $_.Type.trim()
        $tmp5 = $tmp5.tolower()
        $tmp6 = $_.WWNpool.trim()
        $tmp7 = $_.QoS.trim()
        $tmp8 = $_.Org.trim()

        If ($tmp8 -eq "root") {$org = $orgRoot}
        Else {$org = $orgRoot | Get-UcsOrg -Name $tmp8 -LimitScope}

        Start-UcsTransaction
          $mo = $org | Add-UcsVhbaTemplate -Name $tmp1 -Descr $tmp2 -SwitchId $tmp3 -TemplType $tmp5 -IdentPoolName $tmp6 `
              -MaxDataFieldSize 2048 -PinToGroupName "" -PolicyOwner "local" -QosPolicyName $tmp7 -StatsPolicyName "default" -ModifyPresent
          $trash = $mo | Add-UcsVhbaInterface -Name $tmp4 -ModifyPresent
        Complete-UcsTransaction | Out-Null

        If ($error.length -lt 1)
        {
            Write-Log "Add VHBA template - Name=$tmp1 Descr=$tmp2 Fabric=$tmp3 VSAN=$tmp4 Type=$tmp5 Pool=$tmp6 QoS=$tmp7" "Normal"
        }
        Else
        {
            Write-Log "ERROR Add VHBA template - Name=$tmp1 Descr=$tmp2 Fabric=$tmp3 VSAN=$tmp4 Type=$tmp5 Pool=$tmp6 QoS=$tmp7" "Error"
            $errTag = $True
        }
    }
}

##########
# Boot Policies
$present = $false
For ($i=0; $i -lt $objectTable.length; $i++)
{
    $obj = $objectTable[$i]
    If ($obj[0] -eq 'BootPolicy' -and $obj[1] -eq '1') {$present = $true; Break}
}
If ($Present)
{
    $ucsConfig.VSPEX.BootPolicy | ForEach-Object {$_.PolicyName} | ForEach-Object {
        $error.Clear()
        $i = 0
        $tmp1 = $_
        $tmp2 = $_.Name.trim()
        $tmp3 = $_.Descr
        $tmp4 = $_.Org.trim()

        If ($tmp4 -eq "root") {$org = $orgRoot}
        Else {$org = $orgRoot | Get-UcsOrg -Name $tmp4 -LimitScope}

        $mo = $org | Add-UcsBootPolicy -Name $tmp2 -Descr $tmp3 -EnforceVnicName "yes" -PolicyOwner "local" `
            -RebootOnUpdate "no" -ModifyPresent
    
        $tmp1 | ForEach-Object {$_.Var} | ForEach-Object {
            $i++
            $tmp4 = $_.Type.trim()
            $tmp5 = $_.Device1.trim()
            $tmp6 = $_.Device2.trim()
            $tmp7 = $_.PrimaryFabric

            Switch ($tmp4)
            {
                Local
                {
                    Switch ($tmp5)
                    {
                        cdrom
                        {
                            $trash = $mo | Add-UcsLsbootVirtualMedia -Access "read-only" -Order $i -ModifyPresent
                        }
                        floppy
                        {
                            $trash = $mo | Add-UcsLsbootVirtualMedia -Access "read-write" -Order $i -ModifyPresent
                        }
                        localdisk
                        {
                            $mo_1 = $mo | Add-UcsLsbootStorage -Order $i -ModifyPresent
                            $trash = $mo_1 | Add-UcsLsbootLocalStorage
                        }
                    }
                }
                VHBA
                {
                    If ($tmp7 -eq 'A')
                    {
                        Start-UcsTransaction
                          $mo_2 = $mo | Add-UcsLsbootStorage -Order $i -ModifyPresent
                          $mo_2_1 = $mo_2 | Add-UcsLsbootSanImage -Type "primary" -VnicName $tmp5 -ModifyPresent
                          $trash = $mo_2_1 | Add-UcsLsbootSanImagePath -Lun 0 -Type "primary" -Wwn $sanSPAprimary -ModifyPresent
                          $trash = $mo_2_1 | Add-UcsLsbootSanImagePath -Lun 0 -Type "secondary" -Wwn $sanSPBprimary -ModifyPresent
                          $mo_2_2 = $mo_2 | Add-UcsLsbootSanImage -Type "secondary" -VnicName $tmp6 -ModifyPresent
                          $trash = $mo_2_2 | Add-UcsLsbootSanImagePath -Lun 0 -Type "primary" -Wwn $sanSPAsecondary -ModifyPresent
                          $trash = $mo_2_2 | Add-UcsLsbootSanImagePath -Lun 0 -Type "secondary" -Wwn $sanSPBsecondary -ModifyPresent
                        Complete-UcsTransaction | Out-Null
                    }
                    Else
                    {
                        Start-UcsTransaction
                          $mo_2 = $mo | Add-UcsLsbootStorage -Order $i -ModifyPresent
                          $mo_2_1 = $mo_2 | Add-UcsLsbootSanImage -Type "primary" -VnicName $tmp5 -ModifyPresent
                          $trash = $mo_2_1 | Add-UcsLsbootSanImagePath -Lun 0 -Type "primary" -Wwn $sanSPBprimary -ModifyPresent
                          $trash = $mo_2_1 | Add-UcsLsbootSanImagePath -Lun 0 -Type "secondary" -Wwn $sanSPAprimary -ModifyPresent
                          $mo_2_2 = $mo_2 | Add-UcsLsbootSanImage -Type "secondary" -VnicName $tmp6 -ModifyPresent
                          $trash = $mo_2_2 | Add-UcsLsbootSanImagePath -Lun 0 -Type "primary" -Wwn $sanSPBsecondary -ModifyPresent
                          $trash = $mo_2_2 | Add-UcsLsbootSanImagePath -Lun 0 -Type "secondary" -Wwn $sanSPAsecondary -ModifyPresent
                        Complete-UcsTransaction | Out-Null
                    }
                }
                VNIC
                {
                    $mo_1 = $mo | Add-UcsLsbootLan -Order $i -Prot "pxe" -ModifyPresent
                    $trash = $mo_1 | Add-UcsLsbootLanImagePath -VnicName $tmp5 -BootIpPolicyName "" -ISCSIVnicName "" -ImgPolicyName "" -ImgSecPolicyName "" -ProvSrvPolicyName "" -Type "primary"
                }
            }
            If ($error.length -lt 1)
            {
                Write-Log "Add boot policy - Name=$tmp2 Descr=$tmp3" "Normal"
            }
            Else
            {
                Write-Log "ERROR Add boot policy - Name=$tmp1 Descr=$tmp2" "Error"
                $errTag = $True
            }
        }
    }
}

##########
# Service Profile Template
$present = $false
For ($i=0; $i -lt $objectTable.length; $i++)
{
    $obj = $objectTable[$i]
    If ($obj[0] -eq 'SPTemplate' -and $obj[1] -eq '1') {$present = $true; Break}
}
If ($Present)
{
    $ucsConfig.VSPEX.SPTemplate | ForEach-Object {$_.Template} | ForEach-Object {
        $error.Clear()
        $tmp1 = $_
        $tmp2 = $_.Name.trim()
        $tmp3 = $_.Descr
    
        Start-UcsTransaction
          $tmp4 = $_.BIOSProfileName.trim()
          $tmp5 = $_.BootPolicyName.trim()
          $tmp6 = $_.LocalDiskPolicy.trim()
          $tmp7 = $_.MgmtIPPool.trim()
          $tmp8 = "pooled"
          If ($tmp7 -eq "") {$tmp8 = "none"}
          $tmp9 = $_.PowerPolicyName.trim()
          $tmp10 = $_.ScrubPolicyName.trim()
          $tmp11 = $_.UUIDpool.trim()
          $tmp12 = $_.MaintPolicyName.trim()
          $tmp13 = $_.HostFwPolicyName.trim()
          $tmp14 = $_.MgmtAccessPolicyName.trim()
          $tmp15 = $_.MgmtFwPolicyName.trim()
          $tmp16 = $_.StatsPolicyName.trim()
          $tmp17 = $_.Org.trim()
          $tmp18 = $_.WwnnPoolName.trim()
          If ($tmp17 -eq "root") {$org = $orgRoot}
          Else {$org = $orgRoot | Get-UcsOrg -Name $tmp17 -LimitScope}

          $mo = $org | Add-UcsServiceProfile -Name $tmp2 -Type "updating-template" -ModifyPresent `
              -BiosProfileName $tmp4 -BootPolicyName $tmp5 -LocalDiskPolicyName $tmp6 -ExtIPPoolName $tmp7 -ExtIPState $tmp8 `
              -PowerPolicyName $tmp6 -ScrubPolicyName $tmp10 -IdentPoolName $tmp11 -MaintPolicyName $tmp12 `
              -HostFwPolicyName $tmp13 -MgmtAccessPolicyName $tmp14 -MgmtFwPolicyName $tmp15 -StatsPolicyName $tmp16
          $trash = $mo | Add-UcsVnicFcNode -Addr "pool-derived" -IdentPoolName $tmp18 -ModifyPresent
          $trash = $mo | Add-UcsServerPoolAssignment -ModifyPresent -Name "All-chassis" -Qualifier "all-chassis" -RestrictMigration "no"
          $trash = $mo | Set-UcsServerPower -State "admin-up" -Force

#     Process all the VNICs
          $tmp100 = $_.VNICs
          $i = 0
          $tmp100 | ForEach-Object {$_.Var} | ForEach-Object {
              $tmp4 = $_.Name.trim()
              $tmp5 = $_.Templ.trim()
              $i++
              $trash = $mo | Add-UcsVnic -Name $tmp4 -NwTemplName $tmp5 -AdaptorProfileName "Windows" -Order $i -ModifyPresent
          }

#     Process all the VHBAs
          $tmp100 = $_.VHBAs
          $tmp100 | ForEach-Object {$_.Var} | ForEach-Object {
              $tmp4 = $_.Name.trim()
              $tmp5 = $_.Templ.trim()
              $i++
              $mo_1 = $mo | Add-UcsVhba -Name $tmp4  -NwTemplName $tmp5 -AdaptorProfileName "Windows" -Order $i -ModifyPresent
              $trash = $mo_1 | Add-UcsVhbaInterface -Name "" -ModifyPresent
          }
        Complete-UcsTransaction | Out-Null
        If ($error.length -lt 1)
        {
            Write-Log "Add Service Profile Template - Name=$tmp2 Descr=$tmp3" "Normal"
        }
        Else
        {
            Write-Log "ERROR Service Profile Template - Name=$tmp1 Descr=$tmp2" "Error"
            $errTag = $True
        }
    }
}

##########
# Create Service Profiles from Templates
$present = $false
For ($i=0; $i -lt $objectTable.length; $i++)
{
    $obj = $objectTable[$i]
    If ($obj[0] -eq 'ServiceProfile' -and $obj[1] -eq '1') {$present = $true; Break}
}
If ($Present)
{
    $ucsConfig.VSPEX.ServiceProfile | ForEach-Object {$_.Var} | ForEach-Object {
        $error.Clear()
        $tmp1 = $_.Name.trim()
        $tmp2 = $_.Templ.trim()
        $tmp3 = $_.Org.trim()
        If ($tmp3 -eq "root") {$org = $orgRoot}
        Else {$org = $orgRoot | Get-UcsOrg -Name $tmp3 -LimitScope}

        $mo = Get-UcsServiceProfile -Name $tmp2 -Org $org
        If ($mo -eq $null) 
        {
            Write-Log "ERROR Service Profile - invalid template name - Name=$tmp1 Templ=$tmp2 Org=$tmp3" "Error"
            $errTag = $True
        }
        Else
        {
            $trash = $mo | Add-UcsServiceProfileFromTemplate -NewName @($tmp1) -DestinationOrg $org
        }

        If ($error.length -lt 1)
        {
            Write-Log "Add Service Profile - Name=$tmp1 Templ=$tmp2 Org=$tmp3" "Normal"
        }
        Else
        {
            Write-Log "ERROR Service Profile - Name=$tmp1 Templ=$tmp2 Org=$tmp3" "Error"
            $errTag = $True
        }
    }
}


# ------------------------------------------------------------------------------
#
# Wrap up processing and close down
#
# ------------------------------------------------------------------------------

Disconnect-Ucs
If ($errTag)
{
    Write-Host -ForegroundColor Red -BackgroundColor Black "`n`nErrors detected."
}
Set-Location $originalPath
$endTime = Get-Date
$elapsedTime = New-TimeSpan $startTime $endTime
If ($toconsole)
{
    Write-Log "Elapsed time: $($elapsedTime.Hours):$($elapsedTime.Minutes):$($elapsedTime.Seconds)" "Normal"
    Write-Log "End of processing." "Normal"
}
Else
{
    Write-Host -ForegroundColor Yellow -BackgroundColor Black "`n`n-----------------------------------------------------------`n"
    Write-Host "Elapsed time: $($elapsedTime.Hours):$($elapsedTime.Minutes):$($elapsedTime.Seconds)"
    Write-Host "End of processing."
}