# Screenshot Checklist — Synthetic Billing Foundation

Capture only current, reproducible evidence. Do not include personal paths, account credentials, browser tabs, or temporary files.

## Required screenshots

1. `01_architecture.png`
   - Open `docs/architecture/current_architecture.md` in a Mermaid-capable preview or view the rendered README on GitHub.
   - Capture the full pipeline from business activity through reconciliation.

2. `02_aws_generator_summary.png`
   - Run `python -m generator.aws_billing_generator` in the VS Code terminal.
   - Capture the provider, row count, billed cost and exception counts.

3. `03_gcp_generator_summary.png`
   - Run `python -m generator.gcp_billing_generator`.
   - Capture row count, cost before credits, nested credit total and net cost.

4. `04_source_validation.png`
   - Run `python -m validation.run_source_validation`.
   - Capture both provider totals, `PASS_WITH_EXPECTED_EXCEPTIONS`, and `billing_rows_were_combined: false`.

5. `05_focus_reconciliation.png`
   - Open `data/focus_staging/focus_reconciliation.csv` in VS Code.
   - Capture AWS, GCP and all-cloud rows showing zero variance and PASS.

6. `06_test_results.png`
   - Run `python -m pytest`.
   - Capture the complete test result and coverage output without cropping out failures or warnings.

## Storage

Place approved images in:

```text
output/screenshots/
```

Do not commit drafts, duplicates, uncropped images, or filenames such as `final_final_v2.png`.
