Write-Host ""
Write-Host "Installing required Az modules..." -ForegroundColor Cyan
Write-Host ""
Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
'Az.Resources', 'Az.ImageBuilder', 'Az.Compute' | ForEach-Object { 
    if (Get-Module -ListAvailable -Name $_) {
        Write-Host "$_ Already installed" -ForegroundColor Yellow 
    } 
    else {
        try {
            Install-Module -Name $_ -AllowClobber -Confirm:$False -Force  
        }
        catch [Exception] {
            $_.message 
            exit 1
        }
    }    
}

Write-Host ""
Write-Host "Loading azd .env file from current environment"
Write-Host ""

$output = azd env get-values
foreach ($line in $output) {
    if (!$line.Contains('=')) {
        continue
    }

    $name, $value = $line.Split("=")
    $value = $value -replace '^\"|\"$'
    [Environment]::SetEnvironmentVariable($name, $value)
}
Write-Host ""
Write-Host "Environment variables set."
Write-Host ""
 
# Get your current subscription ID  
$subscriptionID = "$env:AZURE_SUBSCRIPTION_ID"
# Destination image resource group  
$resourceGroupName = "$env:AZURE_RESOURCE_GROUP"
# Location  
$location = "$env:AZURE_LOCATION"

# Set up role def names, which need to be unique 
$identityName = "$env:AZURE_IMAGE_BUILDER_IDENTITY"
$imageRoleDefName = "Azure Image Builder Image Def " + $identityName 

# check if subscription is set before continuing
if ($null -eq $subscriptionID) {
    Write-Host "Subscription not set, exiting..."
    exit 0
}

#check if resource group exists and create it if not
$resourceGroup = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
if ($null -eq $resourceGroup) {
    Write-Host "Resource group not found, creating..."
    New-AzResourceGroup -Name $resourceGroupName -Location $location
}

#Check if the identity already exists
Write-Host ""
Write-Host "Check if the identity already exists..."
Write-Host ""

$identity = Get-AzUserAssignedIdentity -SubscriptionId $subscriptionID -ResourceGroupName $resourceGroupName -Name $identityName -ErrorAction SilentlyContinue
$identityNamePrincipalId = $null

if ($null -ne $identity) {
    Write-Information "Identity already exists, skipping creation"
    $identityNamePrincipalId = $identity.PrincipalId
}
else {
    # Create an identity 
    New-AzUserAssignedIdentity -ResourceGroupName $resourceGroupName -Name $identityName -SubscriptionId $subscriptionID -Location $location
    $identityNamePrincipalId = $(Get-AzUserAssignedIdentity -ResourceGroupName $resourceGroupName -Name $identityName).PrincipalId    
}

Write-Host "Check if role definition already exists..."
# check if role definition already exists
$roleDef = Get-AzRoleDefinition -Name $imageRoleDefName -ErrorAction SilentlyContinue
if ($null -ne $roleDef) {
    Write-Host "Role definition already exists, skipping creation"    
}
else {    
    # Create a role definition file 
    $aibRoleImageCreationUrl = "https://raw.githubusercontent.com/azure/azvmimagebuilder/master/solutions/12_Creating_AIB_Security_Roles/aibRoleImageCreation.json" 
    $aibRoleImageCreationPath = "aibRoleImageCreation.json" 

    # Download the configuration 
    Invoke-WebRequest -Uri $aibRoleImageCreationUrl -OutFile $aibRoleImageCreationPath -UseBasicParsing 
        ((Get-Content -path $aibRoleImageCreationPath -Raw) -replace '<subscriptionID>', $subscriptionID) | Set-Content -Path $aibRoleImageCreationPath 
        ((Get-Content -path $aibRoleImageCreationPath -Raw) -replace '<rgName>', $resourceGroupName) | Set-Content -Path $aibRoleImageCreationPath 
        ((Get-Content -path $aibRoleImageCreationPath -Raw) -replace 'Azure Image Builder Service Image Creation Role', $imageRoleDefName) | Set-Content -Path $aibRoleImageCreationPath 

    # Create a role definition 
    New-AzRoleDefinition -InputFile  ./aibRoleImageCreation.json     
}

# Check if role assignment already exists
$roleAssignment = Get-AzRoleAssignment -ObjectId $identityNamePrincipalId -RoleDefinitionName $imageRoleDefName -Scope "/subscriptions/$subscriptionID/resourceGroups/$resourceGroupName" -ErrorAction SilentlyContinue
if ($null -ne $roleAssignment) {
    Write-Host "Role assignment already exists, skipping creation"    
}
else {
    # Grant the role definition to the VM Image Builder service principal 
    New-AzRoleAssignment -ObjectId $identityNamePrincipalId -RoleDefinitionName $imageRoleDefName -Scope "/subscriptions/$subscriptionID/resourceGroups/$resourceGroupName" -ErrorAction SilentlyContinue
}