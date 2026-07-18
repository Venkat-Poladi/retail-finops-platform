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
Write-Host "Retail Co. FinOps - Milestone 12 Financial Planning"
Write-Host "Project: $ProjectId"
Write-Host ""

$RequiredInputObjects = @(
    "retail_finops_core.fct_cloud_cost"
    "retail_finops_core.fct_cost_allocation"
    "retail_finops_core.vw_cloud_cost_allocated"
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
        File = ".\sql\planning\00_create_mart_dataset.sql"
        Name = "Create analytical mart dataset"
    },
    @{
        File = ".\sql\planning\01_monthly_actuals.sql"
        Name = "Create monthly actuals"
    },
    @{
        File = ".\sql\planning\02_budget_plan.sql"
        Name = "Create modeled approved budget"
    },
    @{
        File = ".\sql\planning\03_forecast_versions.sql"
        Name = "Create forecast versions"
    },
    @{
        File = ".\sql\planning\04_forecast_accuracy_and_budget_variance.sql"
        Name = "Calculate forecast accuracy and budget variance"
    },
    @{
        File = ".\sql\planning\05_usage_rate_scope_variance.sql"
        Name = "Calculate usage rate and scope variance"
    },
    @{
        File = ".\sql\planning\06_accruals_and_reversals.sql"
        Name = "Create accruals and reversals"
    },
    @{
        File = ".\sql\planning\07_reclass_and_chargeback_journals.sql"
        Name = "Create reclass and chargeback journals"
    },
    @{
        File = ".\sql\planning\08_close_checklist.sql"
        Name = "Create monthly close checklist"
    },
    @{
        File = ".\sql\controls\11_financial_planning_reconciliation.sql"
        Name = "Run financial planning reconciliation"
    },
    @{
        File = ".\sql\controls\12_monthly_close_data_quality.sql"
        Name = "Run monthly close data-quality controls"
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
    "retail_finops_mart.mart_monthly_actuals"
    "retail_finops_mart.mart_budget"
    "retail_finops_mart.fct_forecast_version"
    "retail_finops_mart.mart_forecast_accuracy"
    "retail_finops_mart.mart_budget_variance"
    "retail_finops_mart.mart_variance_drivers"
    "retail_finops_mart.fct_cloud_accrual"
    "retail_finops_mart.fct_accrual_reversal"
    "retail_finops_mart.fct_reclass_journal"
    "retail_finops_mart.fct_chargeback_journal"
    "retail_finops_mart.mart_close_checklist"
    "retail_finops_control.financial_planning_reconciliation_control"
    "retail_finops_control.monthly_close_data_quality_control"
)

foreach ($ObjectName in $ObjectsToVerify) {
    Write-Host "Checking output: $ObjectName"

    & bq show "${ProjectId}:$ObjectName"

    if ($LASTEXITCODE -ne 0) {
        throw "Expected output object was not created: $ObjectName"
    }
}

Write-Host ""
Write-Host "Milestone 12 financial planning pipeline completed."
Write-Host ""