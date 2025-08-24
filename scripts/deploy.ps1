# 🚀 Script de Despliegue Automatizado - Aviator Trading en GCP
# Automatiza el despliegue completo del sistema Aviator en Google Cloud Platform

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("development", "staging", "production")]
    [string]$Environment = "development",
    
    [Parameter(Mandatory=$true, HelpMessage="ID del proyecto GCP")]
    [string]$ProjectId,
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipTerraform = $false,
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipDocker = $false,
    
    [Parameter(Mandatory=$false)]
    [switch]$Force = $false,
    
    [Parameter(Mandatory=$false)]
    [switch]$Destroy = $false
)

$ErrorActionPreference = "Stop"

# Configuración global
$script:Config = @{
    ProjectId = $ProjectId
    Environment = $Environment
    Region = "us-central1"
    Zone = "us-central1-a"
    InstanceName = "aviator-trading-$Environment"
    DatabaseName = "aviator-db-$Environment"
    StorageBucket = "aviator-storage-$ProjectId-$Environment"
    ServiceAccount = "aviator-deployment-sa@$ProjectId.iam.gserviceaccount.com"
}

# Colores para output
function Write-ColorOutput {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
}

function Write-Step { param([string]$Message) Write-ColorOutput "📋 $Message" "Cyan" }
function Write-Success { param([string]$Message) Write-ColorOutput "✅ $Message" "Green" }
function Write-Warning { param([string]$Message) Write-ColorOutput "⚠️  $Message" "Yellow" }
function Write-Error { param([string]$Message) Write-ColorOutput "❌ $Message" "Red" }
function Write-Info { param([string]$Message) Write-ColorOutput "💡 $Message" "White" }

# Función para verificar dependencias
function Test-Dependencies {
    Write-Step "Verificando dependencias..."
    
    $dependencies = @(
        @{Name="Google Cloud CLI"; Command="gcloud"; InstallCmd="choco install gcloudsdk"},
        @{Name="Terraform"; Command="terraform"; InstallCmd="choco install terraform"},
        @{Name="Docker"; Command="docker"; InstallCmd="choco install docker-desktop"}
    )
    
    $allPresent = $true
    
    foreach ($dep in $dependencies) {
        try {
            $version = & $dep.Command version 2>$null
            if ($version) {
                Write-Success "✓ $($dep.Name) instalado"
            } else {
                throw "No encontrado"
            }
        } catch {
            Write-Error "✗ $($dep.Name) no encontrado"
            Write-Info "Instalar con: $($dep.InstallCmd)"
            $allPresent = $false
        }
    }
    
    return $allPresent
}

# Función para inicializar GCP
function Initialize-GCP {
    Write-Step "Inicializando configuración GCP..."
    
    try {
        # Configurar proyecto
        gcloud config set project $script:Config.ProjectId
        gcloud config set compute/region $script:Config.Region
        gcloud config set compute/zone $script:Config.Zone
        
        Write-Success "Proyecto configurado: $($script:Config.ProjectId)"
        
        # Verificar autenticación
        $account = gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>$null
        if (-not $account) {
            Write-Info "Iniciando autenticación..."
            gcloud auth login
            gcloud auth application-default login
        }
        
        Write-Success "Autenticado como: $account"
        
        # Habilitar APIs necesarias
        $requiredAPIs = @(
            "compute.googleapis.com",
            "sqladmin.googleapis.com",
            "storage.googleapis.com",
            "monitoring.googleapis.com",
            "logging.googleapis.com",
            "secretmanager.googleapis.com"
        )
        
        Write-Info "Habilitando APIs necesarias..."
        foreach ($api in $requiredAPIs) {
            gcloud services enable $api --quiet
        }
        
        Write-Success "APIs habilitadas exitosamente"
        return $true
        
    } catch {
        Write-Error "Error inicializando GCP: $($_.Exception.Message)"
        return $false
    }
}

# Función para preparar Terraform
function Initialize-Terraform {
    Write-Step "Preparando infraestructura con Terraform..."
    
    try {
        $terraformDir = Join-Path $PSScriptRoot "..\terraform"
        
        if (-not (Test-Path $terraformDir)) {
            Write-Error "Directorio de Terraform no encontrado: $terraformDir"
            return $false
        }
        
        Push-Location $terraformDir
        
        # Inicializar Terraform
        Write-Info "Inicializando Terraform..."
        terraform init
        
        # Crear archivo de variables
        $tfVars = @"
project_id = "$($script:Config.ProjectId)"
environment = "$($script:Config.Environment)"
region = "$($script:Config.Region)"
zone = "$($script:Config.Zone)"
instance_name = "$($script:Config.InstanceName)"
database_name = "$($script:Config.DatabaseName)"
storage_bucket = "$($script:Config.StorageBucket)"
service_account_email = "$($script:Config.ServiceAccount)"
"@
        
        $tfVarsFile = "terraform.tfvars"
        $tfVars | Out-File -FilePath $tfVarsFile -Encoding UTF8
        
        Write-Success "Variables de Terraform configuradas"
        
        # Planificar cambios
        Write-Info "Planificando cambios..."
        terraform plan -out=tfplan
        
        if ($Force -or (Read-Host "¿Aplicar cambios de infraestructura? (y/n)") -eq "y") {
            Write-Info "Aplicando cambios..."
            terraform apply tfplan
            Write-Success "Infraestructura desplegada exitosamente"
        } else {
            Write-Warning "Aplicación de Terraform cancelada"
            return $false
        }
        
        Pop-Location
        return $true
        
    } catch {
        Pop-Location
        Write-Error "Error en Terraform: $($_.Exception.Message)"
        return $false
    }
}

# Función para desplegar aplicación
function Deploy-Application {
    Write-Step "Desplegando aplicación Aviator..."
    
    try {
        # Obtener IP de la instancia
        $instanceIP = gcloud compute instances describe $script:Config.InstanceName `
            --zone=$script:Config.Zone `
            --format="value(networkInterfaces[0].accessConfigs[0].natIP)"
        
        if (-not $instanceIP) {
            Write-Error "No se pudo obtener la IP de la instancia"
            return $false
        }
        
        Write-Success "Instancia encontrada: $instanceIP"
        
        # Copiar archivos de aplicación
        Write-Info "Copiando archivos de aplicación..."
        
        $appFiles = @(
            "docker-compose.gcp.yml",
            ".env.gcp",
            "app/*",
            "config/*"
        )
        
        foreach ($file in $appFiles) {
            $sourcePath = Join-Path $PSScriptRoot "..\$file"
            if (Test-Path $sourcePath) {
                gcloud compute scp $sourcePath "$($script:Config.InstanceName):~/aviator/" `
                    --zone=$script:Config.Zone `
                    --recurse
            }
        }
        
        Write-Success "Archivos copiados exitosamente"
        
        # Ejecutar comandos de despliegue en la instancia
        $deployCommands = @(
            "cd ~/aviator",
            "sudo docker-compose -f docker-compose.gcp.yml down",
            "sudo docker-compose -f docker-compose.gcp.yml pull",
            "sudo docker-compose -f docker-compose.gcp.yml up -d",
            "sudo docker-compose -f docker-compose.gcp.yml ps"
        )
        
        Write-Info "Ejecutando comandos de despliegue..."
        
        $commandString = $deployCommands -join " && "
        gcloud compute ssh $script:Config.InstanceName `
            --zone=$script:Config.Zone `
            --command="$commandString"
        
        Write-Success "Aplicación desplegada exitosamente"
        
        # Mostrar información de acceso
        Write-Info "Información de acceso:"
        Write-Info "URL de la aplicación: http://$instanceIP:8080"
        Write-Info "Panel de monitoreo: http://$instanceIP:3000"
        Write-Info "SSH: gcloud compute ssh $($script:Config.InstanceName) --zone=$($script:Config.Zone)"
        
        return $true
        
    } catch {
        Write-Error "Error desplegando aplicación: $($_.Exception.Message)"
        return $false
    }
}

# Función para verificar estado del despliegue
function Test-Deployment {
    Write-Step "Verificando estado del despliegue..."
    
    try {
        # Verificar instancia
        $instanceStatus = gcloud compute instances describe $script:Config.InstanceName `
            --zone=$script:Config.Zone `
            --format="value(status)"
        
        if ($instanceStatus -eq "RUNNING") {
            Write-Success "✓ Instancia en ejecución"
        } else {
            Write-Warning "✗ Instancia no está ejecutándose: $instanceStatus"
        }
        
        # Verificar base de datos
        $dbStatus = gcloud sql instances describe $script:Config.DatabaseName `
            --format="value(state)" 2>$null
        
        if ($dbStatus -eq "RUNNABLE") {
            Write-Success "✓ Base de datos operativa"
        } else {
            Write-Warning "✗ Base de datos no operativa: $dbStatus"
        }
        
        # Verificar bucket de almacenamiento
        $bucketExists = gsutil ls -b "gs://$($script:Config.StorageBucket)" 2>$null
        
        if ($bucketExists) {
            Write-Success "✓ Bucket de almacenamiento disponible"
        } else {
            Write-Warning "✗ Bucket de almacenamiento no encontrado"
        }
        
        # Verificar servicios en la instancia
        Write-Info "Verificando servicios de la aplicación..."
        
        $serviceCheck = gcloud compute ssh $script:Config.InstanceName `
            --zone=$script:Config.Zone `
            --command="sudo docker-compose -f ~/aviator/docker-compose.gcp.yml ps --services --filter status=running" 2>$null
        
        if ($serviceCheck) {
            Write-Success "✓ Servicios de aplicación ejecutándose"
            Write-Info "Servicios activos: $($serviceCheck -join ', ')"
        } else {
            Write-Warning "✗ Algunos servicios pueden no estar ejecutándose"
        }
        
        return $true
        
    } catch {
        Write-Error "Error verificando despliegue: $($_.Exception.Message)"
        return $false
    }
}

# Función para destruir infraestructura
function Remove-Infrastructure {
    Write-Step "Destruyendo infraestructura..."
    
    if (-not $Force) {
        $confirm = Read-Host "¿CONFIRMAS que quieres DESTRUIR toda la infraestructura? (escribe 'DESTROY' para confirmar)"
        if ($confirm -ne "DESTROY") {
            Write-Warning "Destrucción cancelada"
            return $false
        }
    }
    
    try {
        $terraformDir = Join-Path $PSScriptRoot "..\terraform"
        
        if (Test-Path $terraformDir) {
            Push-Location $terraformDir
            
            Write-Info "Destruyendo con Terraform..."
            terraform destroy -auto-approve
            
            Pop-Location
            Write-Success "Infraestructura destruida con Terraform"
        }
        
        # Limpiar recursos adicionales
        Write-Info "Limpiando recursos adicionales..."
        
        # Eliminar imágenes de Docker
        try {
            gcloud container images list --repository="gcr.io/$($script:Config.ProjectId)" --format="value(name)" | ForEach-Object {
                gcloud container images delete $_ --force-delete-tags --quiet
            }
        } catch {
            Write-Warning "No se pudieron eliminar algunas imágenes de contenedor"
        }
        
        Write-Success "Destrucción completada"
        return $true
        
    } catch {
        if (Get-Location | Select-Object -ExpandProperty Path) {
            Pop-Location
        }
        Write-Error "Error destruyendo infraestructura: $($_.Exception.Message)"
        return $false
    }
}

# Función principal
function Main {
    Write-ColorOutput "" "White"
    Write-ColorOutput "🚀 DESPLIEGUE AUTOMATIZADO - AVIATOR TRADING EN GCP" "Cyan"
    Write-ColorOutput "================================================================" "Cyan"
    Write-ColorOutput "Proyecto: $($script:Config.ProjectId)" "White"
    Write-ColorOutput "Entorno: $($script:Config.Environment)" "White"
    Write-ColorOutput "Región: $($script:Config.Region)" "White"
    Write-ColorOutput "================================================================" "Cyan"
    Write-ColorOutput "" "White"
    
    # Modo destrucción
    if ($Destroy) {
        return Remove-Infrastructure
    }
    
    # Verificar dependencias
    if (-not (Test-Dependencies)) {
        Write-Error "Dependencias faltantes. Instala las herramientas requeridas."
        return $false
    }
    
    # Inicializar GCP
    if (-not (Initialize-GCP)) {
        Write-Error "Error inicializando GCP"
        return $false
    }
    
    # Desplegar infraestructura
    if (-not $SkipTerraform) {
        if (-not (Initialize-Terraform)) {
            Write-Error "Error desplegando infraestructura"
            return $false
        }
    } else {
        Write-Warning "Terraform omitido (parámetro -SkipTerraform)"
    }
    
    # Esperar a que la infraestructura esté lista
    Write-Info "Esperando a que la infraestructura esté lista..."
    Start-Sleep -Seconds 30
    
    # Desplegar aplicación
    if (-not $SkipDocker) {
        if (-not (Deploy-Application)) {
            Write-Error "Error desplegando aplicación"
            return $false
        }
    } else {
        Write-Warning "Despliegue de Docker omitido (parámetro -SkipDocker)"
    }
    
    # Verificar despliegue
    Start-Sleep -Seconds 10
    Test-Deployment
    
    Write-ColorOutput "" "White"
    Write-ColorOutput "🎉 DESPLIEGUE COMPLETADO" "Green"
    Write-ColorOutput "================================================================" "Green"
    Write-ColorOutput "" "White"
    
    # Obtener IP para mostrar URLs
    try {
        $instanceIP = gcloud compute instances describe $script:Config.InstanceName `
            --zone=$script:Config.Zone `
            --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>$null
        
        if ($instanceIP) {
            Write-Success "🌐 URLs de acceso:"
            Write-Info "   Aplicación: http://$instanceIP:8080"
            Write-Info "   Monitoreo: http://$instanceIP:3000"
            Write-Info "   SSH: gcloud compute ssh $($script:Config.InstanceName) --zone=$($script:Config.Zone)"
        }
    } catch {
        Write-Warning "No se pudo obtener la IP de la instancia"
    }
    
    Write-ColorOutput "" "White"
    return $true
}

# Ejecutar script principal
if ($MyInvocation.InvocationName -ne '.') {
    $result = Main
    if (-not $result) {
        exit 1
    }
}