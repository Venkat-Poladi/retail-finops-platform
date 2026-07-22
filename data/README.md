# Generated data

The large AWS, GCP, FOCUS-staging, and schema-hardening outputs are deterministic and regenerable. They are intentionally excluded from Git.

Small reviewer-friendly samples are kept in `data/samples/`.

Regenerate the complete local data set with:

```bash
python -m generator.aws_billing_generator
python -m generator.gcp_billing_generator
python -m generator.provider_schema_hardening
python -m normalization.run_focus_normalization
```

The generators use a fixed seed, so repeated runs produce the same modeled results.
