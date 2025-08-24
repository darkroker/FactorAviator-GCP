# 🔍 Script de Verificación de Configuración GCP - Aviator Trading
# Verifica que todos los componentes de GCP estén configurados correctamente

param(
    [Parameter(Mandatory=$true, HelpMessage="ID del proyecto GCP")]
    [string]$ProjectId,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("basic", "detailed", "full")]
    [string]$DetailLevel = "detailed",
    
    [Parameter(Mandatory=$false)]
    [switch]$FixIssues = $false,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("development", "staging", "production")]
    [string]$Environment = "development"
)

$ErrorActionPreference = "Continue"

# Estructura para resultados de verificación
$script:VerificationResults = @{
    Prerequisites = @{}
    Project = @{}
    APIs = @{}
    Billing = @{}
    ServiceAccount = @{}
    Credentials = @{}
    Configuration = @{}
    Network = @{}
    Security = @{}
    Overall = @{ Status = "Unknown"; Score = 0; MaxScore = 0 }
}

# Colores para output
function Write-ColorOutput {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
}

function Write-Step { param([string]$Message) Write-ColorOutput "🔍 $Message" "Cyan" }
function Write-Success { param([string]$Message) Write-ColorOutput "✅ $Message" "Green" }
function Write-Warning { param([string]$Message) Write-ColorOutput "⚠️  $Message" "Yellow" }
function Write-Error { param([string]$Message) Write-ColorOutput "❌ $Message" "Red" }
function Write-Info { param([string]$Message) Write-ColorOutput "💡 $Message" "White" }
function Write-Fix { param([string]$Message) Write-ColorOutput "🔧 $Message" "Magenta" }

# Función para verificar prerequisitos
function Test-Prerequisites {
    Write-Step "Verificando prerequisitos del sistema..."
    
    $results = @{}
    
    # Verificar Google Cloud CLI
    try {
        $gcloudVersion = gcloud version --format="value(Google Cloud SDK)" 2>$null
        if ($gcloudVersion) {
            $results.GCloudCLI = @{ Status = "OK"; Version = $gcloudVersion; Message = "Google Cloud CLI instalado" }
            Write-Success "Google Cloud CLI: $gcloudVersion"
        } else {
            throw "No encontrado"
        }
    } catch {
        $results.GCloudCLI = @{ Status = "ERROR"; Message = "Google Cloud CLI no instalado" }
        Write-Error "Google Cloud CLI no encontrado"
        if ($FixIssues) {
            Write-Fix "Sugerencia: choco install gcloudsdk"
        }
    }
    
    # Verificar autenticación
    try {
        $account = gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>$null
        if ($account) {
            $results.Authentication = @{ Status = "OK"; Account = $account; Message = "Cuenta autenticada" }
            Write-Success "Autenticado como: $account"
        } else {
            throw "No autenticado"
        }
    } catch {
        $results.Authentication = @{ Status = "ERROR"; Message = "No hay cuenta autenticada" }
        Write-Error "No hay cuenta autenticada"
        if ($FixIssues) {
            Write-Fix "Ejecutando: gcloud auth login"
            gcloud auth login
        }
    }
    
    # Verificar PowerShell
    $psVersion = $PSVersionTable.PSVersion.ToString()
    if ($PSVersionTable.PSVersion.Major -ge 5) {
        $results.PowerShell = @{ Status = "OK"; Version = $psVersion; Message = "PowerShell compatible" }
        Write-Success "PowerShell: $psVersion"
    } else {
        $results.PowerShell = @{ Status = "WARNING"; Version = $psVersion; Message = "Versión de PowerShell antigua" }
        Write-Warning "PowerShell: $psVersion (recomendado 5.0+)"
    }
    
    $script:VerificationResults.Prerequisites = $results
    return $results
}

# Función para verificar proyecto
function Test-Project {
    Write-Step "Verificando configuración del proyecto..."
    
    $results = @{}
    
    # Verificar existencia del proyecto
    try {
        $projectInfo = gcloud projects describe $ProjectId --format="json" 2>$null | ConvertFrom-Json
        if ($projectInfo) {
            $results.Existence = @{ Status = "OK"; ProjectId = $ProjectId; Name = $projectInfo.name; Message = "Proyecto existe" }
            Write-Success "Proyecto encontrado: $($projectInfo.name)"
            
            # Verificar estado del proyecto
            if ($projectInfo.lifecycleState -eq "ACTIVE") {
                $results.State = @{ Status = "OK"; State = $projectInfo.lifecycleState; Message = "Proyecto activo" }
                Write-Success "Estado del proyecto: ACTIVO"
            } else {
                $results.State = @{ Status = "ERROR"; State = $projectInfo.lifecycleState; Message = "Proyecto no activo" }
                Write-Error "Estado del proyecto: $($projectInfo.lifecycleState)"
            }
        } else {
            throw "Proyecto no encontrado"
        }
    } catch {
        $results.Existence = @{ Status = "ERROR"; Message = "Proyecto no encontrado o sin acceso" }
        Write-Error "Proyecto '$ProjectId' no encontrado o sin acceso"
    }
    
    # Verificar configuración de gcloud
    try {
        $currentProject = gcloud config get-value project 2>$null
        $currentRegion = gcloud config get-value compute/region 2>$null
        $currentZone = gcloud config get-value compute/zone 2>$null
        
        if ($currentProject -eq $ProjectId) {
            $results.Configuration = @{ 
                Status = "OK"; 
                Project = $currentProject; 
                Region = $currentRegion; 
                Zone = $currentZone; 
                Message = "Configuración correcta" 
            }
            Write-Success "Proyecto configurado: $currentProject"
            Write-Success "Región: $currentRegion, Zona: $currentZone"
        } else {
            $results.Configuration = @{ Status = "WARNING"; Message = "Proyecto no configurado como activo" }
            Write-Warning "Proyecto activo: $currentProject (esperado: $ProjectId)"
            if ($FixIssues) {
                Write-Fix "Configurando proyecto..."
                gcloud config set project $ProjectId
            }
        }
    } catch {
        $results.Configuration = @{ Status = "ERROR"; Message = "Error obteniendo configuración" }
        Write-Error "Error verificando configuración de gcloud"
    }
    
    $script:VerificationResults.Project = $results
    return $results
}

# Función para verificar APIs
function Test-APIs {
    Write-Step "Verificando APIs habilitadas..."
    
    $results = @{}
    
    $requiredAPIs = @(
        @{Name="Compute Engine"; Service="compute.googleapis.com"},
        @{Name="Cloud SQL Admin"; Service="sqladmin.googleapis.com"},
        @{Name="Cloud Storage"; Service="storage.googleapis.com"},
        @{Name="Cloud Build"; Service="cloudbuild.googleapis.com"},
        @{Name="Cloud Monitoring"; Service="monitoring.googleapis.com"},
        @{Name="Secret Manager"; Service="secretmanager.googleapis.com"},
        @{Name="Cloud Resource Manager"; Service="cloudresourcemanager.googleapis.com"},
        @{Name="IAM"; Service="iam.googleapis.com"}
    )
    
    try {
        $enabledServices = gcloud services list --enabled --format="value(name)" 2>$null
        
        foreach ($api in $requiredAPIs) {
            if ($enabledServices -contains $api.Service) {
                $results[$api.Name] = @{ Status = "OK"; Service = $api.Service; Message = "API habilitada" }
                Write-Success "✓ $($api.Name)"
            } else {
                $results[$api.Name] = @{ Status = "ERROR"; Service = $api.Service; Message = "API no habilitada" }
                Write-Error "✗ $($api.Name) no habilitada"
                if ($FixIssues) {
                    Write-Fix "Habilitando $($api.Name)..."
                    gcloud services enable $api.Service --quiet
                }
            }
        }
    } catch {
        Write-Error "Error verificando APIs: $($_.Exception.Message)"
        $results.Error = @{ Status = "ERROR"; Message = "Error verificando APIs" }
    }
    
    $script:VerificationResults.APIs = $results
    return $results
}

# Función para verificar billing
function Test-Billing {
    Write-Step "Verificando configuración de facturación..."
    
    $results = @{}
    
    try {
        # Verificar cuenta de billing vinculada
        $billingAccount = gcloud beta billing projects describe $ProjectId --format="value(billingAccountName)" 2>$null
        
        if ($billingAccount) {
            $results.Account = @{ Status = "OK"; Account = $billingAccount; Message = "Cuenta de billing vinculada" }
            Write-Success "Cuenta de billing: $billingAccount"
            
            # Verificar estado de la cuenta
            $accountId = $billingAccount.Split('/')[-1]
            $accountInfo = gcloud beta billing accounts describe $accountId --format="json" 2>$null | ConvertFrom-Json
            
            if ($accountInfo -and $accountInfo.open) {
                $results.Status = @{ Status = "OK"; Open = $accountInfo.open; Message = "Cuenta de billing activa" }
                Write-Success "Estado de billing: ACTIVA"
            } else {
                $results.Status = @{ Status = "WARNING"; Message = "Cuenta de billing cerrada o inaccesible" }
                Write-Warning "Cuenta de billing puede estar cerrada"
            }
        } else {
            $results.Account = @{ Status = "ERROR"; Message = "No hay cuenta de billing vinculada" }
            Write-Error "No hay cuenta de billing vinculada"
        }
        
        # Verificar presupuestos
        try {
            $budgets = gcloud beta billing budgets list --billing-account=$accountId --format="value(displayName)" 2>$null
            if ($budgets) {
                $results.Budgets = @{ Status = "OK"; Count = ($budgets | Measure-Object).Count; Message = "Presupuestos configurados" }
                Write-Success "Presupuestos configurados: $($budgets -join ', ')"
            } else {
                $results.Budgets = @{ Status = "WARNING"; Message = "No hay presupuestos configurados" }
                Write-Warning "No hay presupuestos configurados"
            }
        } catch {
            $results.Budgets = @{ Status = "WARNING"; Message = "No se pudieron verificar presupuestos" }
            Write-Warning "No se pudieron verificar presupuestos"
        }
        
    } catch {
        $results.Error = @{ Status = "ERROR"; Message = "Error verificando billing" }
        Write-Error "Error verificando billing: $($_.Exception.Message)"
    }
    
    $script:VerificationResults.Billing = $results
    return $results
}

# Función para verificar Service Account
function Test-ServiceAccount {
    Write-Step "Verificando Service Account..."
    
    $results = @{}
    $serviceAccountName = "aviator-deployment-sa"
    $serviceAccountEmail = "$serviceAccountName@$ProjectId.iam.gserviceaccount.com"
    
    try {
        # Verificar existencia
        $saInfo = gcloud iam service-accounts describe $serviceAccountEmail --format="json" 2>$null | ConvertFrom-Json
        
        if ($saInfo) {
            $results.Existence = @{ Status = "OK"; Email = $serviceAccountEmail; Message = "Service Account existe" }
            Write-Success "Service Account encontrada: $serviceAccountEmail"
            
            # Verificar roles
            $roles = gcloud projects get-iam-policy $ProjectId --flatten="bindings[].members" --format="table(bindings.role)" --filter="bindings.members:$serviceAccountEmail" 2>$null
            
            $requiredRoles = @(
                "roles/compute.admin",
                "roles/cloudsql.admin",
                "roles/storage.admin",
                "roles/monitoring.editor"
            )
            
            $assignedRoles = @()
            if ($roles) {
                $assignedRoles = $roles | Where-Object { $_ -match "roles/" }
            }
            
            $missingRoles = $requiredRoles | Where-Object { $assignedRoles -notcontains $_ }
            
            if ($missingRoles.Count -eq 0) {
                $results.Roles = @{ Status = "OK"; Assigned = $assignedRoles; Message = "Todos los roles asignados" }
                Write-Success "Roles verificados: $($assignedRoles.Count) asignados"
            } else {
                $results.Roles = @{ Status = "WARNING"; Missing = $missingRoles; Assigned = $assignedRoles; Message = "Faltan algunos roles" }
                Write-Warning "Roles faltantes: $($missingRoles -join ', ')"
                if ($FixIssues) {
                    foreach ($role in $missingRoles) {
                        Write-Fix "Asignando rol: $role"
                        gcloud projects add-iam-policy-binding $ProjectId --member="serviceAccount:$serviceAccountEmail" --role="$role" --quiet
                    }
                }
            }
        } else {
            $results.Existence = @{ Status = "ERROR"; Message = "Service Account no encontrada" }
            Write-Error "Service Account no encontrada: $serviceAccountEmail"
            if ($FixIssues) {
                Write-Fix "Creando Service Account..."
                gcloud iam service-accounts create $serviceAccountName --display-name="Aviator Deployment SA"
            }
        }
    } catch {
        $results.Error = @{ Status = "ERROR"; Message = "Error verificando Service Account" }
        Write-Error "Error verificando Service Account: $($_.Exception.Message)"
    }
    
    $script:VerificationResults.ServiceAccount = $results
    return $results
}

# Función para verificar credenciales
function Test-Credentials {
    Write-Step "Verificando archivos de credenciales..."
    
    $results = @{}
    
    # Verificar archivo de credenciales JSON
    $credentialsPath = Join-Path $PSScriptRoot "..\credentials\aviator-gcp-credentials.json"
    
    if (Test-Path $credentialsPath) {
        try {
            $credentialsContent = Get-Content $credentialsPath -Raw | ConvertFrom-Json
            
            if ($credentialsContent.project_id -eq $ProjectId) {
                $results.JSONFile = @{ Status = "OK"; Path = $credentialsPath; ProjectId = $credentialsContent.project_id; Message = "Archivo de credenciales válido" }
                Write-Success "Credenciales JSON válidas: $credentialsPath"
            } else {
                $results.JSONFile = @{ Status = "WARNING"; Path = $credentialsPath; Message = "Proyecto en credenciales no coincide" }
                Write-Warning "Proyecto en credenciales ($($credentialsContent.project_id)) no coincide con $ProjectId"
            }
        } catch {
            $results.JSONFile = @{ Status = "ERROR"; Path = $credentialsPath; Message = "Archivo de credenciales inválido" }
            Write-Error "Archivo de credenciales inválido o corrupto"
        }
    } else {
        $results.JSONFile = @{ Status = "ERROR"; Path = $credentialsPath; Message = "Archivo de credenciales no encontrado" }
        Write-Error "Archivo de credenciales no encontrado: $credentialsPath"
    }
    
    # Verificar variable de entorno
    $envCredentials = $env:GOOGLE_APPLICATION_CREDENTIALS
    if ($envCredentials) {
        if (Test-Path $envCredentials) {
            $results.Environment = @{ Status = "OK"; Path = $envCredentials; Message = "Variable de entorno configurada" }
            Write-Success "GOOGLE_APPLICATION_CREDENTIALS: $envCredentials"
        } else {
            $results.Environment = @{ Status = "WARNING"; Path = $envCredentials; Message = "Archivo en variable de entorno no existe" }
            Write-Warning "Archivo en GOOGLE_APPLICATION_CREDENTIALS no existe"
        }
    } else {
        $results.Environment = @{ Status = "WARNING"; Message = "Variable GOOGLE_APPLICATION_CREDENTIALS no configurada" }
        Write-Warning "Variable GOOGLE_APPLICATION_CREDENTIALS no configurada"
        if ($FixIssues -and (Test-Path $credentialsPath)) {
            Write-Fix "Configurando variable de entorno..."
            [Environment]::SetEnvironmentVariable("GOOGLE_APPLICATION_CREDENTIALS", $credentialsPath, "User")
        }
    }
    
    $script:VerificationResults.Credentials = $results
    return $results
}

# Función para verificar archivos de configuración
function Test-Configuration {
    Write-Step "Verificando archivos de configuración..."
    
    $results = @{}
    
    $configFiles = @(
        @{Name="Configuración GCP"; Path=".env.gcp"; Required=$true},
        @{Name="Docker Compose GCP"; Path="docker-compose.gcp.yml"; Required=$true},
        @{Name="Terraform Main"; Path="gcp\terraform\main.tf"; Required=$false},
        @{Name="Script de Deploy"; Path="gcp\scripts\deploy.ps1"; Required=$false}
    )
    
    foreach ($file in $configFiles) {
        $fullPath = Join-Path $PSScriptRoot "..\$($file.Path)"
        
        if (Test-Path $fullPath) {
            $results[$file.Name] = @{ Status = "OK"; Path = $fullPath; Message = "Archivo encontrado" }
            Write-Success "✓ $($file.Name): $($file.Path)"
        } else {
            if ($file.Required) {
                $results[$file.Name] = @{ Status = "ERROR"; Path = $fullPath; Message = "Archivo requerido no encontrado" }
                Write-Error "✗ $($file.Name): $($file.Path) (REQUERIDO)"
            } else {
                $results[$file.Name] = @{ Status = "WARNING"; Path = $fullPath; Message = "Archivo opcional no encontrado" }
                Write-Warning "⚠ $($file.Name): $($file.Path) (opcional)"
            }
        }
    }
    
    $script:VerificationResults.Configuration = $results
    return $results
}

# Función para generar reporte
function Write-VerificationReport {
    Write-Step "Generando reporte de verificación..."
    
    $totalChecks = 0
    $passedChecks = 0
    
    # Calcular puntuación
    foreach ($category in $script:VerificationResults.Keys) {
        if ($category -eq "Overall") { continue }
        
        foreach ($check in $script:VerificationResults[$category].Keys) {
            $totalChecks++
            if ($script:VerificationResults[$category][$check].Status -eq "OK") {
                $passedChecks++
            }
        }
    }
    
    $score = if ($totalChecks -gt 0) { [math]::Round(($passedChecks / $totalChecks) * 100, 1) } else { 0 }
    
    # Determinar estado general
    $overallStatus = if ($score -ge 90) { "EXCELENTE" }
                    elseif ($score -ge 75) { "BUENO" }
                    elseif ($score -ge 50) { "ACEPTABLE" }
                    else { "REQUIERE ATENCIÓN" }
    
    $script:VerificationResults.Overall = @{
        Status = $overallStatus
        Score = $score
        MaxScore = 100
        PassedChecks = $passedChecks
        TotalChecks = $totalChecks
    }
    
    # Generar reporte
    $report = @"

🎯 REPORTE DE VERIFICACIÓN - AVIATOR TRADING GCP
================================================================

📊 PUNTUACIÓN GENERAL: $score% ($passedChecks/$totalChecks)
🏆 ESTADO: $overallStatus

📋 RESUMEN POR CATEGORÍAS:

"@
    
    foreach ($category in @("Prerequisites", "Project", "APIs", "Billing", "ServiceAccount", "Credentials", "Configuration")) {
        if ($script:VerificationResults.ContainsKey($category)) {
            $categoryResults = $script:VerificationResults[$category]
            $categoryPassed = ($categoryResults.Values | Where-Object { $_.Status -eq "OK" }).Count
            $categoryTotal = $categoryResults.Count
            $categoryScore = if ($categoryTotal -gt 0) { [math]::Round(($categoryPassed / $categoryTotal) * 100, 1) } else { 0 }
            
            $statusIcon = if ($categoryScore -ge 80) { "✅" } elseif ($categoryScore -ge 50) { "⚠️" } else { "❌" }
            
            $report += "$statusIcon $category`: $categoryScore% ($categoryPassed/$categoryTotal)`n"
        }
    }
    
    $report += @"

🔧 RECOMENDACIONES:

"@
    
    # Agregar recomendaciones basadas en los resultados
    if ($script:VerificationResults.Prerequisites.GCloudCLI.Status -ne "OK") {
        $report += "• Instalar Google Cloud CLI: choco install gcloudsdk`n"
    }
    
    if ($script:VerificationResults.Prerequisites.Authentication.Status -ne "OK") {
        $report += "• Autenticar con GCP: gcloud auth login`n"
    }
    
    if ($script:VerificationResults.Billing.Account.Status -ne "OK") {
        $report += "• Configurar cuenta de billing en la consola de GCP`n"
    }
    
    if ($script:VerificationResults.ServiceAccount.Existence.Status -ne "OK") {
        $report += "• Crear Service Account: .\setup-gcp-steps.ps1 -ProjectId $ProjectId`n"
    }
    
    $report += @"

🌐 ENLACES ÚTILES:
• Consola GCP: https://console.cloud.google.com/home/dashboard?project=$ProjectId
• Billing: https://console.cloud.google.com/billing/linkedaccount?project=$ProjectId
• IAM: https://console.cloud.google.com/iam-admin/iam?project=$ProjectId
• APIs: https://console.cloud.google.com/apis/dashboard?project=$ProjectId

"@
    
    Write-ColorOutput $report "Cyan"
    
    # Guardar reporte en archivo
    $reportFile = "gcp-verification-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
    $report | Out-File -FilePath $reportFile -Encoding UTF8
    Write-Info "Reporte guardado en: $reportFile"
    
    return $script:VerificationResults.Overall
}

# Función principal
function Main {
    Write-ColorOutput "" "White"
    Write-ColorOutput "🔍 VERIFICACIÓN DE CONFIGURACIÓN GCP - AVIATOR TRADING" "Cyan"
    Write-ColorOutput "================================================================" "Cyan"
    Write-ColorOutput "Proyecto: $ProjectId" "White"
    Write-ColorOutput "Entorno: $Environment" "White"
    Write-ColorOutput "Nivel de detalle: $DetailLevel" "White"
    Write-ColorOutput "Corregir problemas: $FixIssues" "White"
    Write-ColorOutput "================================================================" "Cyan"
    Write-ColorOutput "" "White"
    
    # Ejecutar verificaciones
    $verificationSteps = @(
        @{Name="Prerequisitos"; Function={Test-Prerequisites}},
        @{Name="Proyecto"; Function={Test-Project}},
        @{Name="APIs"; Function={Test-APIs}},
        @{Name="Billing"; Function={Test-Billing}},
        @{Name="Service Account"; Function={Test-ServiceAccount}},
        @{Name="Credenciales"; Function={Test-Credentials}},
        @{Name="Configuración"; Function={Test-Configuration}}
    )
    
    foreach ($step in $verificationSteps) {
        Write-ColorOutput "" "White"
        try {
            & $step.Function | Out-Null
        } catch {
            Write-Error "Error en verificación de $($step.Name): $($_.Exception.Message)"
        }
    }
    
    # Generar reporte final
    Write-ColorOutput "" "White"
    $overallResult = Write-VerificationReport
    
    Write-ColorOutput "" "White"
    if ($overallResult.Score -ge 75) {
        Write-Success "🎉 Configuración lista para despliegue"
        Write-Info "Ejecuta: .\deploy.ps1 -ProjectId $ProjectId -Environment $Environment"
    } else {
        Write-Warning "⚠️ Configuración requiere atención antes del despliegue"
        Write-Info "Revisa las recomendaciones y ejecuta con -FixIssues para corregir automáticamente"
    }
    
    return $overallResult.Score -ge 50
}

# Ejecutar script principal
if ($MyInvocation.InvocationName -ne '.') {
    $result = Main
    if (-not $result) {
        exit 1
    }
}