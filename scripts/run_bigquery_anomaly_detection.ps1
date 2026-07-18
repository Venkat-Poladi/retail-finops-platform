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
Write-Host "Retail Co. FinOps - Milestone 13 Anomaly Detection"
Write-Host "Project: $ProjectId"
Write-Host ""

$RequiredInputObjects = @(
    "retail_finops_core.fct_cloud_cost"
    "retail_finops_raw.raw_aws_billing"
    "retail_finops_raw.raw_gcp_billing"
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
        File = ".\sql\anomaly\01_daily_cost_series.sql"
        Name = "Create daily cost series"
    },
    @{
        File = ".\sql\anomaly\02_anomaly_scores.sql"
        Name = "Calculate anomaly scores"
    },
    @{
        File = ".\sql\anomaly\03_fct_cost_anomaly.sql"
        Name = "Create anomaly fact table"
    },
    @{
        File = ".\sql\anomaly\04_anomaly_source_detail.sql"
        Name = "Create anomaly source detail"
    },
    @{
        File = ".\sql\anomaly\05_anomaly_summary.sql"
        Name = "Create anomaly summary"
    },
    @{
        File = ".\sql\controls\13_anomaly_reconciliation.sql"
        Name = "Run anomaly reconciliation"
    },
    @{
        File = ".\sql\controls\14_anomaly_data_quality.sql"
        Name = "Run anomaly data-quality controls"
    },
    @{
        File = ".\sql\controls\15_known_anomaly_detection.sql"
        Name = "Validate injected anomaly detection"
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
    "retail_finops_mart.mart_daily_cost_series"
    "retail_finops_mart.mart_cost_anomaly_score"
    "retail_finops_mart.fct_cost_anomaly"
    "retail_finops_mart.fct_anomaly_source_detail"
    "retail_finops_mart.mart_anomaly_summary"
    "retail_finops_control.anomaly_reconciliation_control"
    "retail_finops_control.anomaly_data_quality_control"
    "retail_finops_control.known_anomaly_detection_control"
)

foreach ($ObjectName in $ObjectsToVerify) {
    Write-Host "Checking output: $ObjectName"

    & bq show "${ProjectId}:$ObjectName"

    if ($LASTEXITCODE -ne 0) {
        throw "Expected output object was not created: $ObjectName"
    }
}

Write-Host ""
Write-Host "Milestone 13 anomaly-detection pipeline completed."
Write-Host ""