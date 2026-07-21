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

function Assert-CsvColumns {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$RequiredColumns
    )

    if (-not (Test-Path -LiteralPath $FilePath)) {
        throw "Required CSV file not found: $FilePath"
    }

    $HeaderObject = Import-Csv `
        -LiteralPath $FilePath |
        Select-Object -First 1

    if ($null -eq $HeaderObject) {
        throw "CSV file contains no data rows: $FilePath"
    }

    $ActualColumns = $HeaderObject.PSObject.Properties.Name

    $MissingColumns = @(
        $RequiredColumns |
            Where-Object {
                $_ -notin $ActualColumns
            }
    )

    if ($MissingColumns.Count -gt 0) {
        $MissingColumnText = $MissingColumns -join ", "

        throw "CSV file is missing required columns: $MissingColumnText. File: $FilePath"
    }
}

Write-Host ""
Write-Host "Retail Co. FinOps - Milestone 15 Unit Economics"
Write-Host "Project: $ProjectId"
Write-Host ""

$ActivitySourceFile = (
    Resolve-Path `
        ".\data\business_activity\business_activity.csv"
).Path

$DimensionSourceFile = (
    Resolve-Path `
        ".\config\business_dimensions.csv"
).Path

$ActivityColumns = @(
    "activity_date"
    "workload_id"
    "environment"
    "business_driver"
    "demand_index"
    "traffic"
    "transactions"
    "queries"
    "support_requests"
    "ai_requests"
    "api_requests"
    "active_customers"
    "revenue"
)

$DimensionColumns = @(
    "workload_id"
    "application_name"
    "department_name"
    "environment"
    "cost_center"
    "owner_team"
    "business_driver"
)

Assert-CsvColumns `
    -FilePath $ActivitySourceFile `
    -RequiredColumns $ActivityColumns

Assert-CsvColumns `
    -FilePath $DimensionSourceFile `
    -RequiredColumns $DimensionColumns

$TemporaryFolder = Join-Path `
    $env:TEMP `
    "retail_finops_unit_economics"

New-Item `
    -ItemType Directory `
    -Path $TemporaryFolder `
    -Force | Out-Null

$NormalizedActivityFile = Join-Path `
    $TemporaryFolder `
    "business_activity_normalized.csv"

$NormalizedDimensionFile = Join-Path `
    $TemporaryFolder `
    "business_dimensions_normalized.csv"

Import-Csv `
    -LiteralPath $ActivitySourceFile |
    Select-Object $ActivityColumns |
    Export-Csv `
        -LiteralPath $NormalizedActivityFile `
        -NoTypeInformation `
        -Encoding UTF8

Import-Csv `
    -LiteralPath $DimensionSourceFile |
    Select-Object $DimensionColumns |
    Export-Csv `
        -LiteralPath $NormalizedDimensionFile `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host ""
Write-Host "Checking required BigQuery datasets"

$RequiredDatasets = @(
    "retail_finops_raw"
    "retail_finops_core"
    "retail_finops_mart"
    "retail_finops_control"
)

foreach ($DatasetName in $RequiredDatasets) {
    & bq show "${ProjectId}:$DatasetName"

    if ($LASTEXITCODE -ne 0) {
        throw "Required BigQuery dataset does not exist: $DatasetName"
    }
}

Write-Host ""
Write-Host "Checking allocation input"

& bq show `
    "${ProjectId}:retail_finops_core.fct_cost_allocation"

if ($LASTEXITCODE -ne 0) {
    throw "Required input does not exist: fct_cost_allocation"
}

Write-Host ""
Write-Host "Loading normalized business activity"

$ActivitySchema = @(
    "activity_date:DATE"
    "workload_id:STRING"
    "environment:STRING"
    "business_driver:STRING"
    "demand_index:NUMERIC"
    "traffic:NUMERIC"
    "transactions:NUMERIC"
    "queries:NUMERIC"
    "support_requests:NUMERIC"
    "ai_requests:NUMERIC"
    "api_requests:NUMERIC"
    "active_customers:NUMERIC"
    "revenue:NUMERIC"
) -join ","

$ActivityLoadArguments = @(
    "load"
    "--replace"
    "--source_format=CSV"
    "--skip_leading_rows=1"
    "--project_id=$ProjectId"
    "${ProjectId}:retail_finops_raw.raw_business_activity"
    $NormalizedActivityFile
    $ActivitySchema
)

& bq @ActivityLoadArguments

if ($LASTEXITCODE -ne 0) {
    throw "Failed to load raw_business_activity."
}

Write-Host ""
Write-Host "Loading business dimension reference"

$DimensionSchema = @(
    "workload_id:STRING"
    "application_name:STRING"
    "department_name:STRING"
    "environment:STRING"
    "cost_center:STRING"
    "owner_team:STRING"
    "business_driver:STRING"
) -join ","

$DimensionLoadArguments = @(
    "load"
    "--replace"
    "--source_format=CSV"
    "--skip_leading_rows=1"
    "--project_id=$ProjectId"
    "${ProjectId}:retail_finops_control.business_dimension_reference"
    $NormalizedDimensionFile
    $DimensionSchema
)

& bq @DimensionLoadArguments

if ($LASTEXITCODE -ne 0) {
    throw "Failed to load business_dimension_reference."
}

$Steps = @(
    @{
        File = ".\sql\unit_economics\01_business_activity_monthly.sql"
        Name = "Create monthly business activity"
    },
    @{
        File = ".\sql\unit_economics\02_unit_economics_cost_base.sql"
        Name = "Create unit economics cost base"
    },
    @{
        File = ".\sql\unit_economics\03_mart_unit_economics.sql"
        Name = "Create application unit economics"
    },
    @{
        File = ".\sql\unit_economics\04_mart_unit_economics_trend.sql"
        Name = "Create unit economics trends"
    },
    @{
        File = ".\sql\unit_economics\05_mart_unit_economics_summary.sql"
        Name = "Create executive unit economics summary"
    },
    @{
        File = ".\sql\controls\20_unit_economics_reconciliation.sql"
        Name = "Run unit economics reconciliation"
    },
    @{
        File = ".\sql\controls\21_unit_economics_data_quality.sql"
        Name = "Run unit economics data-quality controls"
    },
    @{
        File = ".\sql\controls\22_unit_economics_period_alignment.sql"
        Name = "Run unit economics period alignment"
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
    "retail_finops_raw.raw_business_activity"
    "retail_finops_control.business_dimension_reference"
    "retail_finops_mart.mart_business_activity_monthly"
    "retail_finops_mart.mart_unit_economics_cost_base"
    "retail_finops_mart.mart_unit_economics"
    "retail_finops_mart.mart_unit_economics_trend"
    "retail_finops_mart.mart_unit_economics_summary"
    "retail_finops_control.unit_economics_reconciliation_control"
    "retail_finops_control.unit_economics_data_quality_control"
    "retail_finops_control.unit_economics_period_alignment_control"
)

foreach ($ObjectName in $ObjectsToVerify) {
    Write-Host "Checking output: $ObjectName"

    & bq show "${ProjectId}:$ObjectName"

    if ($LASTEXITCODE -ne 0) {
        throw "Expected BigQuery object was not created: $ObjectName"
    }
}

Remove-Item `
    -LiteralPath $NormalizedActivityFile `
    -Force `
    -ErrorAction SilentlyContinue

Remove-Item `
    -LiteralPath $NormalizedDimensionFile `
    -Force `
    -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Milestone 15 unit-economics pipeline completed."
Write-Host ""
