$ErrorActionPreference = "Stop"

Write-Host "Running AWS synthetic billing generator..."
python -m generator.aws_billing_generator
if ($LASTEXITCODE -ne 0) { throw "AWS generator failed." }

Write-Host "Running GCP synthetic billing generator..."
python -m generator.gcp_billing_generator
if ($LASTEXITCODE -ne 0) { throw "GCP generator failed." }

Write-Host "Applying provider schema hardening..."
python -m generator.provider_schema_hardening
if ($LASTEXITCODE -ne 0) { throw "Provider schema hardening failed." }

Write-Host "Running source validation..."
python -m validation.run_source_validation
if ($LASTEXITCODE -ne 0) { throw "Source validation failed." }

Write-Host "Running FOCUS normalization and reconciliation..."
python -m normalization.run_focus_normalization
if ($LASTEXITCODE -ne 0) { throw "FOCUS normalization failed." }

Write-Host "Running the full automated test suite..."
python -m pytest
if ($LASTEXITCODE -ne 0) { throw "Tests failed." }

Write-Host "Milestone 8A completed successfully."
