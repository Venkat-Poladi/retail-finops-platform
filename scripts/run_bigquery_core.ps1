[CmdletBinding()]
param(
    [string]$ProjectId = "finops-learning-lab"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot

function Invoke-BigQuerySqlFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "SQL file not found: $Path"
    }

    $SqlText = Get-Content -LiteralPath $Path -Raw
    $SqlText = $SqlText.Replace("__PROJECT_ID__", $ProjectId)
    $SqlText = $SqlText.Replace('${PROJECT_ID}', $ProjectId)

    if ($SqlText -match '__PROJECT_ID__|\$\{PROJECT_ID\}') {
        throw "An unresolved project placeholder remains in: $Path"
    }

    Write-Host ""
    Write-Host "Running: $Path" -ForegroundColor Cyan

    $SqlText | bq query `
        --project_id=$ProjectId `
        --use_legacy_sql=false `
        --format=pretty

    if ($LASTEXITCODE -ne 0) {
        throw "BigQuery execution failed for: $Path"
    }
}

$SqlFiles = @(
    (Join-Path $ProjectRoot "sql\core\01_create_core_dataset.sql"),
    (Join-Path $ProjectRoot "sql\core\02_fct_cloud_cost.sql"),
    (Join-Path $ProjectRoot "sql\controls\06_fact_reconciliation.sql"),
    (Join-Path $ProjectRoot "sql\controls\07_fact_data_quality.sql")
)

foreach ($SqlFile in $SqlFiles) {
    Invoke-BigQuerySqlFile -Path $SqlFile
}

Write-Host ""
Write-Host "Milestone 10 BigQuery build completed." -ForegroundColor Green

$SummarySql = @'
SELECT
    'FACT_ROWS' AS control_name,
    CAST(COUNT(*) AS STRING) AS control_value
FROM `__PROJECT_ID__.retail_finops_core.fct_cloud_cost`

UNION ALL

SELECT
    'FACT_BILLED_COST',
    CAST(ROUND(SUM(billed_cost), 6) AS STRING)
FROM `__PROJECT_ID__.retail_finops_core.fct_cloud_cost`

UNION ALL

SELECT
    'RECONCILIATION_FAILURES',
    CAST(COUNTIF(reconciliation_status <> 'PASS') AS STRING)
FROM `__PROJECT_ID__.retail_finops_control.fact_reconciliation`

UNION ALL

SELECT
    'DATA_QUALITY_FAILURES',
    CAST(COUNTIF(check_status <> 'PASS') AS STRING)
FROM `__PROJECT_ID__.retail_finops_control.fact_data_quality`;
'@.Replace('__PROJECT_ID__', $ProjectId)

Write-Host ""
Write-Host "Final control summary:" -ForegroundColor Cyan

$SummarySql | bq query `
    --project_id=$ProjectId `
    --use_legacy_sql=false `
    --format=pretty

if ($LASTEXITCODE -ne 0) {
    throw "Final Milestone 10 control summary failed."
}
