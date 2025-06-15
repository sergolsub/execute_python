#!/usr/bin/env bash
set -euo pipefail

# Expect AWS_REGION, CODE_ZIP_S3, REQS_S3, DF_S3, OUT_PREFIX in env

# 1) download zip & requirements
aws --region "${AWS_REGION}" s3 cp "${CODE_ZIP_S3}" code.zip
aws --region "${AWS_REGION}" s3 cp "${REQS_S3}" requirements.txt

# 2) unpack & install
unzip code.zip -d code
pip install --no-cache-dir -r requirements.txt

# 3) run inline Python
python3 <<'PYCODE'
import os, json, boto3, importlib.util, pandas as pd
from io import StringIO

AWS_REGION = os.environ["AWS_REGION"]
DF_S3      = os.environ["DF_S3"]
OUT_PREFIX = os.environ["OUT_PREFIX"]

# Strip off "s3://", then split into bucket/key
path = DF_S3.replace("s3://", "")
bucket, key = path.split("/", 1)

s3 = boto3.client("s3", region_name=AWS_REGION)
obj = s3.get_object(Bucket=bucket, Key=key)
if key.lower().endswith(".csv"):
    df = pd.read_csv(obj["Body"])
else:
    df = pd.read_parquet(obj["Body"])

# Load user code
spec = importlib.util.spec_from_file_location("usercode", "code/main.py")
mod  = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)

# Execute
result, out_df = mod.run(df)

# Write back result.json
out_bucket, out_prefix = OUT_PREFIX.split("/",1)
s3.put_object(
    Bucket=out_bucket,
    Key=f"{out_prefix}/result.json",
    Body=json.dumps(result).encode()
)

# Write back dataframe.csv
buf = StringIO()
out_df.to_csv(buf, index=False)
s3.put_object(
    Bucket=out_bucket,
    Key=f"{out_prefix}/dataframe.csv",
    Body=buf.getvalue().encode()
)

print("Done")
PYCODE
