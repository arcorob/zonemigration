# Script to move VMs from an existing region Load Balancer into Availability Zones
# The VMs in the existing Load Balancer are spread across all supported zones in the target region
#
# Usage: .\MoveLBVMstoAZs.ps1 -subid yoursubid -lbname yourlbname -lbresourcegroup yourlbresourcegrp
# 
# subid - The subscription ID for the VMs and Load Balancer to Migrate
# lbname - Azure LB containing the VMs to move to Availability Zones
# lbresourcegroup - Resource group of Azure LB containing the VMs to move to Availability Zones
#
# -------------------------------------------Version change history ------------------------------------------------------------------#
# Beta 1.0 - 02/28/2018
# Beta 1.1 - 03/05/2018 - Added check for Powershell and ARM versions to prevent cmdlet errors 
#
# -------------------------------------------------------------------------------------------------------------------------------------------#
#Created by Bob Roudebush 
#
#CONTACT FOR SUPPORT 
# Robert Arco - Azure Resiliency
# rarco@microsoft.com
#-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------#
#-------------------------------------------------------Check PowerShell version to prevent errors---------------------------------------------------------------------------------#
#Check PowerShell Version
$psVersion = $PSVersionTable.PSVersion
If ($psVersion -le "5.1.16299")
      {Write-host "You are running Powershell Version" $psVersion "and need to run 5.1.6 or higher" -ForegroundColor Red
              Write-Host "Please upgrade to the latest version of Powershell if you wish to run this script" -ForegroundColor Red
              Write-Host "Script aborting"
       Exit}

Else
      {Write-host "Powershell Version is valid for script" $psVersion} 
      

#----------------------------------------------------Check ARM version to prevent errors ----------------------------------------------------------------------------------------
$armVersion = Get-Module AzureRM -ListAvailable | Select-Object -Property Version
#Write-Host $armVersion
$var =$armVersion -Split ("=")
#Write-Host $var[1]
$var2 = $var[1] -split ("}")
Write-Host $var2[0] "ARM Version"
If ($var2[0] -lt "5.2.0")    
   {Write-Host "Script Requires ARM version 5.2.0 or higher" -ForegroundColor Red
    Write-Host "Please upgrade to the latest version of ARM if you wish to run this script" -ForegroundColor Red
    Write-Host "Aborting script" -ForegroundColor Red
        Exit}  

Else 
    {Write-host "ARM version is valid for script "}
## Issue Warning and verify the customer understands the impact #
Write-Host "WARNING - The running of this script should only be performed understanding the potential for loss and downtime" -ForegroundColor Red
Write-Host "WARNING - Your VM(s) will experience down time during this process" -ForegroundColor Red
Write-Host "WARNING - This script will move your Virtual Machines to Zones and will delete the originals at a later stage" -ForegroundColor Red
Write-Host "WARNING - Script Failure after VM deletion could result in lost VM(s) " -ForegroundColor Red
Write-Host "WARNING - Always ensure you have a path to recover in case of loss" -ForegroundColor Red
$proceedanswer = Read-Host "If you still wish to proceed, please reply Y - null value or N aborts"

If ($proceedanswer -ne "Y")
    {Write-Host "Reply is not Y - Aborting " -ForegroundColor Red
    Exit}

Else 
{Write-host "Proceeding at customer request"}

#----------------------------------------------------------------------Program Starts---------------------------------------------------------------------------------------------------------------------------------#
param(
        [Parameter(Mandatory=$true)]
        [string]$subid,
        [Parameter(Mandatory=$true)]
        [string]$lbname,
        [parameter(Mandatory=$true)]
        [string]$lbresourcegroup
    )
# ----------------------------------------------------------------------------------------#
# Populate these variables with values if testing, otherwise these come from parameters
# ----------------------------------------------------------------------------------------#
# $subid = "yoursubid"                 # Azure Subscription ID
# $lbname = "yourlb"                                                # Source Load Balancer VMs to Move to AZs
# $lbresourcegroup = "yourlbresourcegrp"                             # Source Load Balancer VMs Resource Group

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------------------------------ #
# Try to Select Azure Subscription - Prompt to Login if Unsuccessful
# ------------------------------------------------------------------------------------ #
try {
  $sub = Select-AzureRmSubscription -SubscriptionId $subid -ErrorAction Stop
}
Catch {
  Login-AzureRmAccount
  Select-AzureRmSubscription -SubscriptionId $subid
}

function CreateDiskFromSnap {
    Param ($diskrg,$diskname,$zone)
  
    $snapsourcedisk = Get-AzureRmDisk -ResourceGroupName $diskrg -DiskName $diskname
    
      if ($snapsourcedisk.Sku.Name -eq $null) { 
          Write-Host "Azure PowerShell Cmdlet Version Not Supported - Update to Latest Version" -ForegroundColor Red
          Exit
      }
    
      $snapshotconfig =  New-AzureRmSnapshotConfig -SourceUri $snapsourcedisk.Id -CreateOption Copy -Location $snapsourcedisk.Location -SkuName $snapsourcedisk.Sku.Name
      $snapshotname = $snapsourcedisk.Name+"_snap"
      Write-Host "Creating snapshot of managed disk"$diskname -ForegroundColor Cyan
      $snapshot = New-AzureRmSnapshot -Snapshot $snapshotconfig -SnapshotName $snapshotname -ResourceGroupName $diskrg -ErrorAction Stop
    
      $newdiskconfig = New-AzureRmDiskConfig -SourceResourceId $snapshot.Id -Location $snapshot.Location -CreateOption Copy -Zone $zone -SkuName $snapshot.Sku.Name
      $newdiskname = $snapsourcedisk.Name+"_az"
      Write-Host "Creating new managed disk"$newdiskname -ForegroundColor Cyan
      $disk = New-AzureRmDisk -Disk $newdiskConfig -DiskName $newdiskname -ResourceGroupName $diskrg -ErrorAction Stop
    
      return $disk
  }

function RecreateVM {
  Param ($name,$rg,$zone)

  # Check to see if VM is running. VM must be in a running state to query Storage Account Type for Premium Disks
  $oldvmstatus = Get-AzureRmVM -ResourceGroupName $rg -Name $name -Status | Select-Object @{n="Status"; e={$_.Statuses[1].Code}} 
  if ($oldvmstatus.Status -ne "PowerState/running") {
    Write-Host "VM is not Running. Please start the VM and re-run the script." -ForegroundColor Red
    Exit 
  }

  # Get Source VM Configuration and Store It
  $oldvm = Get-AzureRmVM -ResourceGroupName $rg -Name $name -WarningAction Stop
  $outputfilename = $name+"-configbackup.json"
  Write-Host "Backing up VM configuration to"$outputfilename -ForegroundColor Yellow
  try {
    ConvertTo-Json -InputObject $oldvm -Depth 10 > $outputfilename -ErrorAction Stop
  }
  Catch {
    Write-Host "Unable to save VM configuration backup to current directory. Aborting." -ForegroundColor Red
  }

  # Script Doesn't Deal with VMs Encrypted using ADE - Abort if Detected
  $osVolEncrypted = (Get-AzureRmVMDiskEncryptionStatus -ResourceGroupName $oldvm.ResourceGroupName -VMName $oldvm.Name -ErrorAction SilentlyContinue).OsVolumeEncrypted 
  $dataVolEncrypted = (Get-AzureRmVMDiskEncryptionStatus -ResourceGroupName $oldvm.ResourceGroupName -VMName $oldvm.Name -ErrorAction SilentlyContinue).DataVolumesEncrypted
  if ($osVolEncrypted -eq "Encrypted" -or $dataVolEncrypted -eq "Encrypted" ) {
    Write-Host "VM is Encrypted - Aborting Script" -ForegroundColor Red
    Exit
  }

  # Script is Designed to work with Managed Disk Only - Abort if Detected
  if ($oldvm.StorageProfile.OsDisk.ManagedDisk -eq $null) {
    Write-Host "VM is Using Unmanaged Disks - Aborting Script" -ForegroundColor Red
    Exit
  }

  Write-Host "Creating New VM Configuration" -ForegroundColor Cyan

  # ----------------------------------------------------------------------------------------#
  # Create VM Configuration for Destination VM - Provide Zone Info
  # ----------------------------------------------------------------------------------------#
  $SupportedZones = (Get-AzureRmComputeResourceSku | Where-Object {$_.Locations.Contains($oldvm.Location) -and ($_.Name -eq $oldvm.HardwareProfile.VmSize)}).LocationInfo.Zones
  if ($SupportedZones.Count -lt 1) {
    # If Resoruce API returns no zones for this VM Size, then it's not supported
    Write-Host "VM Size Not Supported by Availability Zones - Aborting Script" -ForegroundColor Red
    Exit
  }
  elseif (!($SupportedZones -contains $zone)) {
    # If the list of zones for this VM Size and Region doesn't contain the specified zone then abort
    Write-Host "Zone Specified Not Supported for this VM Size in this Region - Aborting Script" -ForegroundColor Red
    Exit
  }
  else {
    $newvmconfig = New-AzureRmVMConfig -VMName $name -VMSize $oldvm.HardwareProfile.VmSize -Zone $zone
    # Add any Tags from Old VM to New VM
    $newvmconfig.Tags = $oldvm.Tags

    Write-Host "VM Created in Availability Zone $($newvmconfig.Zones) in $($oldvm.location) " -ForegroundColor Green
  }

  # ----------------------------------------------------------------------------------------#
  # Create Storage Profiles for Destination VM
  # ----------------------------------------------------------------------------------------#

  # Stop Source VM If It's Not Stopped before Snapshots are Taken
  Write-Host "Stopping VM"$oldvm.Name -ForegroundColor Yellow
  Stop-AzureRmVM -Name $oldvm.Name -ResourceGroupName $oldvm.ResourceGroupName -Force

  # Create New OS Disk from Snapshot of Existing OS Disk
   $newdisk = CreateDiskFromSnap -diskrg $oldvm.StorageProfile.OsDisk.ManagedDisk.Id.Split("/")[4] -diskname $oldvm.StorageProfile.OsDisk.Name -zone $zone
  
  # Add OS Disk to New VM configuration using old values - Detect Windows/Linux
  If ($oldvm.StorageProfile.OsDisk.OsType -eq "Windows") {
    $newvmconfig | Set-AzureRmVmOSDisk -Name $newdisk.Name -CreateOption Attach -ManagedDiskId $newdisk.Id -StorageAccountType $newdisk.Sku.Name -Caching ($oldvm.StorageProfile.OsDisk.Caching) -DiskSizeInGB $newdisk.DiskSizeGB -Windows -ErrorAction Stop
  }
  ElseIf ($oldvm.StorageProfile.OsDisk.OsType -eq "Linux") {
    $newvmconfig | Set-AzureRmVmOSDisk -Name $newdisk.Name -CreateOption Attach -ManagedDiskId $newdisk.Id -StorageAccountType $newdisk.Sku.Name -Caching ($oldvm.StorageProfile.OsDisk.Caching) -DiskSizeInGB $newdisk.DiskSizeGB -Linux -ErrorAction Stop
  }

  # Iterate Through Each Data Disk and Add to New VM Configuration
  For ($i=0;$i -lt ($oldvm.StorageProfile.DataDisks.Count).ToInt32($null);$i++) {
    # Create New Data Disk from Snapshot of Existing Data Disk
    $newdisk = CreateDiskFromSnap -diskrg $oldvm.StorageProfile.DataDisks[$i].ManagedDisk.Id.Split("/")[4] -diskname $oldvm.StorageProfile.DataDisks[$i].Name -zone $zone

    # Add Data Disk to new VM Configuration Using Old Values
    $newvmconfig | Add-AzureRmVMDataDisk -Name $newdisk.Name -ManagedDiskId $newdisk.Id -StorageAccountType $newdisk.Sku.Name -Caching ($oldvm.StorageProfile.DataDisks[$i].Caching) -Lun ($oldvm.StorageProfile.DataDisks[$i].Lun) -DiskSizeInGB $newdisk.DiskSizeGB -CreateOption Attach -ErrorAction Stop
  } 

  # ----------------------------------------------------------------------------------------#
  # Delete Old VM Before NICs are Created
  # ----------------------------------------------------------------------------------------#
  Write-Host "Deleting VM Configuration prior to recreation in Availability Zone" -ForegroundColor Yellow
  Remove-AzureRmVM -Name $name -ResourceGroupName $rg -WarningAction Stop

  # ----------------------------------------------------------------------------------------#
  # Create NICs for Destination VM
  # ----------------------------------------------------------------------------------------#

  # Handle Multi-NIC VMs by Iterating Through Each Interface
  For ($i=0;$i -lt ($oldvm.NetworkProfile.NetworkInterfaces.Count).ToInt32($null);$i++) {
    # Get Old NIC Name and Resource Group from ID
    $nicname = ($oldvm.NetworkProfile.NetworkInterfaces[$i].id.Split("/")[8])
    $oldnicRG = ($oldvm.NetworkProfile.NetworkInterfaces[$i].Id.Split("/")[4])
    $newIPAddress = ""

    # Store NIC Configuration Temporary Variable
    $oldnic = Get-AzureRmNetworkInterface -Name $nicname -ResourceGroupName $oldnicRG
  
    # Remove Old NICs
    # Write-Host "Removing NIC"$oldnic.Name"from VM"$oldvm.Name -ForegroundColor Yellow
    # Remove-AzureRmNetworkInterface -Name $oldnic.Name -ResourceGroupName $oldnic.ResourceGroupName -Force -WarningAction SilentlyContinue

    # Check to See if Old VM Has a PIP Assigned
    If ($oldnic.IpConfigurations[0].PublicIpAddress.Id) {
      Write-Host "VM Has a Public IP Assigned - Attaching Same PIP to new VM" -ForegroundColor Yellow
    }
  
    # Check to See if Old VM NICs Had Static IP
    If ($oldnic.IpConfigurations[0].PrivateIpAllocationMethod -eq "Static") {
      Write-Host "Source NIC has Static IP Address ("$oldnic.IpConfigurations[0].PrivateIpAddress") - using same IP" -ForegroundColor Yellow 
      $newIPAddress = $oldnic.IpConfigurations[0].PrivateIpAddress
    }

    # Check to See if Old VM NICs had NSG
    If ($oldnic.NetworkSecurityGroup -ne $null) {
      Write-Host "Source VM NIC had NSG Assigned - Attaching NSG to new VM NIC" -ForegroundColor Yellow 
    }
    # This Assumes one IP Configuration per NIC - WILL NOT COPY ADDITIONAL IP CONFIGS
    $nic = New-AzureRmNetworkInterface -Name $nicname -ResourceGroupName $rg -Location $oldvm.Location -SubnetId $oldnic.IpConfigurations[0].Subnet.Id `
    -NetworkSecurityGroupId $oldnic.NetworkSecurityGroup.Id -PrivateIpAddress $newIPAddress -PublicIpAddressId $oldnic.IpConfigurations[0].PublicIpAddress.Id `
    -Force -WarningAction SilentlyContinue -ErrorAction Stop
    
    If ($i -eq 0) {
      $newvmconfig | Add-AzureRmVMNetworkInterface -Id $nic.Id -Primary -WarningAction SilentlyContinue
    } Else {
      $newvmconfig | Add-AzureRmVMNetworkInterface -Id $nic.Id -WarningAction SilentlyContinue
    }
  }

  # ----------------------------------------------------------------------------------------#
  # Deploy Destination VM
  # ----------------------------------------------------------------------------------------#
  Write-Host
  Write-Host "VM Configuration Creation Complete. Recreating VM." -ForegroundColor Green
  $vm = New-AzureRmVM -ResourceGroupName $rg -Location $oldvm.Location -VM $newvmconfig -ErrorAction Stop -WarningAction SilentlyContinue

  Return $vm
}

# ------------------------------------------------------------------------------------ #
# Get Old LB Configuration using parameters provided to script
# ------------------------------------------------------------------------------------ #

$lb = Get-AzureRmLoadBalancer -ResourceGroupName $lbresourcegroup -Name $lbname
$bepoolconfig = Get-AzureRmLoadBalancerBackendAddressPoolConfig -LoadBalancer $lb
$natruleconfig = Get-AzureRmLoadBalancerInboundNatRuleConfig -LoadBalancer $lb

# ------------------------------------------------------------------------------------ #
# Check to see if LB is Standard or Basic SKU - if Basic, exit script
# ------------------------------------------------------------------------------------ #
If ($lb.Sku.Name -eq "Basic") {
  Write-Host "Load Balancer is not Standard SKU. First migrate LB to Standard SKU before continuing." -ForegroundColor Red
  Exit 
}

# ------------------------------------------------------------------------------------ #
# Enumerate the VMs in the Load Balancer and insert names/rgs into array
# ------------------------------------------------------------------------------------ #
$vmnames = @()
$vmrgs = @()
foreach ($BackendIpConfig in $bepoolconfig.BackendIpConfigurations) {
    # Pull NIC Name from IP Config
    $nicname = $BackendIpConfig.Id.Split("/")[8]
    # Pull NIC RG Name from IP Config
    $nicrgname = $BackendIpConfig.Id.Split("/")[4]
    # Get NIC Properties for each IP Config in old Backend Pool
    $nic = Get-AzureRmNetworkInterface -Name $nicname -ResourceGroupName $nicrgname

    # Check for Public IP Addresses Attached to VMs - Abort if Found
    foreach ($ipconfig in $nic.IpConfigurations) {
        if ($ipconfig.PublicIpAddress -ne $null -or $ipconfig.PublicIpAddress -eq "") {
          Write-Host "VM Found with Public IP Address Attached. Remove all Public IPs before Migrating VMs to AZs." -ForegroundColor Red
          Exit
        }
    }

    # Pull VM Name/RG from NIC Configuration
    $vmrgs += $nic.VirtualMachine.Id.Split("/")[4]
    $vmnames += $nic.VirtualMachine.Id.Split("/")[8]
}

# ------------------------------------------------------------------------------------ #
# For each VM in the Load Balancer, recreate it in an Availability Zone
# ------------------------------------------------------------------------------------ #
For ($i=0;$i -lt ($vmnames.Count.ToInt32($null));$i++) {
  $vmName = $vmnames[$i]
  $vmresourcegroup = $vmrgs[$i]

  $vm = Get-AzureRmVM -ResourceGroupName $vmresourcegroup -Name $vmName
  $SupportedZones = (Get-AzureRmComputeResourceSku | Where-Object {$_.Locations.Contains($vm.Location) -and ($_.Name -eq $vm.HardwareProfile.VmSize)}).LocationInfo.Zones
  
  # MOD function ensures VMs are spread across the supported Number of Zones for that VM Size/Region
  $targetzone = ($i%$SupportedZones.Count)+1         

  Write-Host
  Write-Host "Processing VM $vmname in RG $vmresourcegroup into AZ $targetzone" -ForegroundColor White
  $newvm = RecreateVM -name $vmname -rg $vmresourcegroup -zone $targetzone -ErrorAction Stop
  Write-Host "VM $vmname recreation complete." -ForegroundColor Green
}

# ------------------------------------------------------------------------------------ #
# Rejoin VM NICs to Load Balancer - Note: Only handles one BE Pool Currently
# ------------------------------------------------------------------------------------ #
Write-Host
Write-Host "Processing VM NICs to Reassign to Load Balancer Backend Pool" -ForegroundColor White
# Go through old Backend Pool Config and Inspect each IP Config Listed
foreach ($BackendIpConfig in $bepoolconfig.BackendIpConfigurations) {
    # Pull NIC RG Name from IP Config
    $nicrgname = $BackendIpConfig.Id.Split("/")[4]
    # Pull NIC Name from IP Config
    $nicname = $BackendIpConfig.Id.Split("/")[8]

    # Get NIC Properties for each IP Config in Backend Pool
    $nic = Get-AzureRmNetworkInterface -Name $nicname -ResourceGroupName $nicrgname

    foreach ($ipconfig in $nic.IpConfigurations) {
      # Parse NIC IP Configs and Find One That Matches IP Config from BE Pool  
      if ($ipconfig.Name -eq $BackendIpConfig.Id.Split("/")[10]) {
        # Pull VM Name from NIC Configuration
        $vmname = $nic.VirtualMachine.Id.Split("/")[8]
        Write-Host
        Write-Host "Assigning $nicname/$($ipconfig.Name) of $vmname to backend address pool $($bepoolconfig.Name)" -ForegroundColor Cyan
        # Add LB BE Pool to NIC IP Config LB Backend Address Pools List
        $ipconfig.LoadBalancerBackendAddressPools.Add($bepoolconfig)
        # Go Through Inbound NAT Rules Looking for Same NIC IP Config
        foreach ($natrule in $natruleconfig) {
          # If Current NIC IP Config Matches Inbound NAT Rule IP Config Then Add NAT Rule to NIC IP Config
          if ($ipconfig.Id -eq $natrule.BackendIPConfiguration.Id) {
            Write-Host "Found NAT Rule Match for $($natrule.Name)...Assigning to $nicname/$($ipconfig.Name)" -ForegroundColor Cyan
            # Add New NAT Rule to NIC IP Config LB Inbound NAT Rules List
            $ipconfig.LoadBalancerInboundNatRules.Add($natrule)
          }
        }
      }
      # Once BE Address List and NAT Rules List are Updated, Push NIC Config to Azure
      Write-Host "Writing NIC Configuration Changes to Azure" -ForegroundColor Green
      Set-AzureRmNetworkInterface -NetworkInterface $nic > $null
    }
}