param(
    [Parameter(Mandatory = $false)]
    [string]$ProjectId = "finops-learning-lab"
)

$ErrorActionPreference = "Stop"

function Invoke-BigQuerySqlFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string]$StepName
    )

    if (-not (Test-Path -LiteralPath $FilePath)) {
        throw "Required SQL file not found: $FilePath"
    }

    Write-Host ""
    Write-Host "--------------------------------------------------"
    Write-Host "Running: $StepName"
    Write-Host "File: $FilePath"
    Write-Host "--------------------------------------------------"

    $Sql = Get-Content `
        -LiteralPath $FilePath `
        -Raw

    if ([string]::IsNullOrWhiteSpace($Sql)) {
        throw "SQL file is empty: $FilePath"
    }

    $Sql = $Sql.Replace(
        "__PROJECT_ID__",
        $ProjectId
    )

    $BqArguments = @(
        "query"
        "--project_id=$ProjectId"
        "--use_legacy_sql=false"
        "--format=pretty"
    )

    $Sql | & bq @BqArguments

    if ($LASTEXITCODE -ne 0) {
        throw "BigQuery step failed: $StepName"
    }

    Write-Host "Completed: $StepName"
}

Write-Host ""
Write-Host "Retail Co. FinOps - Milestone 14 Optimization"
Write-Host "Project: $ProjectId"
Write-Host ""

$RequiredInputObjects = @(
    "retail_finops_core.fct_cloud_cost"
    "retail_finops_mart.fct_cost_anomaly"
)

foreach ($ObjectName in $RequiredInputObjects) {
    Write-Host "Checking input: $ObjectName"

    & bq show "${ProjectId}:$ObjectName"

    if ($LASTEXITCODE -ne 0) {
        throw "Required input object does not exist: $ObjectName"
    }
}

$Steps = @(
    @{
        File = ".\sql\optimization\01_optimization_rule_catalog.sql"
        Name = "Create optimization rule catalog"
    },
    @{
        File = ".\sql\optimization\02_resource_cost_baseline.sql"
        Name = "Create resource optimization baseline"
    },
    @{
        File = ".\sql\optimization\03_commitment_discount_analysis.sql"
        Name = "Create commitment discount analysis"
    },
    @{
        File = ".\sql\optimization\04_optimization_recommendation_candidates.sql"
        Name = "Generate recommendation candidates"
    },
    @{
        File = ".\sql\optimization\05_mart_optimization.sql"
        Name = "Create final optimization mart"
    },
    @{
        File = ".\sql\optimization\06_optimization_source_detail.sql"
        Name = "Create optimization source detail"
    },
    @{
        File = ".\sql\optimization\07_mart_savings_funnel.sql"
        Name = "Create savings lifecycle funnel"
    },
    @{
        File = ".\sql\controls\16_optimization_reconciliation.sql"
        Name = "Run optimization reconciliation"
    },
    @{
        File = ".\sql\controls\17_optimization_data_quality.sql"
        Name = "Run optimization data-quality controls"
    },
    @{
        File = ".\sql\controls\18_optimization_overlap_control.sql"
        Name = "Run optimization overlap controls"
    },
    @{
        File = ".\sql\controls\19_savings_lifecycle_control.sql"
        Name = "Run savings lifecycle controls"
    }
)

foreach ($Step in $Steps) {
    Invoke-BigQuerySqlFile `
        -FilePath $Step.File `
        -StepName $Step.Name
}

Write-Host ""
Write-Host "--------------------------------------------------"
Write-Host "Verifying output objects"
Write-Host "--------------------------------------------------"

$ObjectsToVerify = @(
    "retail_finops_control.optimization_rule_catalog"
    "retail_finops_mart.mart_optimization_resource_baseline"
    "retail_finops_mart.mart_commitment_discount_analysis"
    "retail_finops_mart.optimization_recommendation_candidates"
    "retail_finops_mart.mart_optimization"
    "retail_finops_mart.optimization_source_detail"
    "retail_finops_mart.mart_savings_funnel"
    "retail_finops_control.optimization_reconciliation_control"
    "retail_finops_control.optimization_data_quality_control"
    "retail_finops_control.optimization_overlap_control"
    "retail_finops_control.savings_lifecycle_control"
)

foreach ($ObjectName in $ObjectsToVerify) {
    Write-Host "Checking output: $ObjectName"

    & bq show "${ProjectId}:$ObjectName"

    if ($LASTEXITCODE -ne 0) {
        throw "Expected output object was not created: $ObjectName"
    }
}

Write-Host ""
Write-Host "Milestone 14 optimization pipeline completed."
Write-Host ""
