"""Verify that the required project packages can be imported."""


def test_required_packages_can_be_imported() -> None:
    import boto3
    import dotenv
    import numpy
    import openpyxl
    import pandas
    import pyarrow
    import pytest
    import requests
    import yaml
    from google.cloud import bigquery

    required_packages = [
        boto3,
        dotenv,
        numpy,
        openpyxl,
        pandas,
        pyarrow,
        pytest,
        requests,
        yaml,
        bigquery,
    ]

    assert all(package is not None for package in required_packages)
    