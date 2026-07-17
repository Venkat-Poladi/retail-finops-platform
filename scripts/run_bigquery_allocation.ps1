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

    $Sql = Get-Content -LiteralPath $FilePath -Raw

    if ([string]::IsNullOrWhiteSpace($Sql)) {
        throw "SQL file is empty: $FilePath"
    }

    $Sql = $Sql.Replace("__PROJECT_ID__", $ProjectId)

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
Write-Host "Retail Co. FinOps - Milestone 11 Allocation"
Write-Host "Project: $ProjectId"
Write-Host ""

$Steps = @(
    @{
        File = ".\sql\allocation\01_allocation_driver_weights.sql"
        Name = "Create allocation driver weights"
    },
    @{
        File = ".\sql\allocation\02_fct_cost_allocation.sql"
        Name = "Create allocation fact table"
    },
    @{
        File = ".\sql\allocation\03_vw_cloud_cost_allocated.sql"
        Name = "Create allocated cloud cost view"
    },
    @{
        File = ".\sql\controls\08_allocation_reconciliation.sql"
        Name = "Run allocation reconciliation"
    },
    @{
        File = ".\sql\controls\09_allocation_data_quality.sql"
        Name = "Run allocation data-quality controls"
    },
    @{
        File = ".\sql\controls\10_allocation_health.sql"
        Name = "Calculate allocation health"
    }
)

foreach ($Step in $Steps) {
    Invoke-BigQuerySqlFile `
        -FilePath $Step.File `
        -StepName $Step.Name
}

Write-Host ""
Write-Host "--------------------------------------------------"
Write-Host "Verifying created BigQuery objects"
Write-Host "--------------------------------------------------"

$ObjectsToVerify = @(
    "retail_finops_core.allocation_driver_weight"
    "retail_finops_core.fct_cost_allocation"
    "retail_finops_core.vw_cloud_cost_allocated"
    "retail_finops_control.allocation_reconciliation_control"
    "retail_finops_control.allocation_data_quality_control"
    "retail_finops_control.allocation_health_control"
)

foreach ($ObjectName in $ObjectsToVerify) {
    Write-Host "Checking: $ObjectName"

    & bq show "${ProjectId}:$ObjectName"

    if ($LASTEXITCODE -ne 0) {
        throw "Expected BigQuery object was not created: $ObjectName"
    }
}

Write-Host ""
Write-Host "Milestone 11 allocation pipeline completed."
Write-Host ""
