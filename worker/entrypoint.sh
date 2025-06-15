#!/usr/bin/env bash
set -euo pipefail

# env vars:
# CODE_ZIP_S3, REQS_S3, DF_S3, OUT_PREFIX
aws --region $AWS_REGION s3 cp $CODE_ZIP_S3 code.zip
aws --region $AWS_REGION s3 cp $REQS_S3 requirements.txt
unzip code.zip -d code
pip install --no-cache-dir -r requirements.txt
pip install pandas boto3

# assume user code has main.py with a run(df)->(dict,DataFrame)
python3 - <<'PYCODE'
import sys, os, boto3, importlib.util, pandas as pd, json
from io import StringIO

# load dataframe
df_obj = boto3.client("s3").get_object(Bucket="$(${DF_S3#s3://*/})", Key="${DF_S3#s3://*/}")
df = pd.read_csv(df_obj['Body']) if DF_S3.endswith('.csv') else pd.read_parquet(df_obj['Body'])

# load user code
spec = importlib.util.spec_from_file_location("usercode","code/main.py")
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)

result, out_df = mod.run(df)
# write outputs
bucket, prefix = "$OUT_PREFIX".split("/",1)
s3 = boto3.client("s3")
s3.put_object(Bucket=bucket, Key=f"{prefix}/result.json", Body=json.dumps(result))
csv_buf = StringIO(); out_df.to_csv(csv_buf, index=False)
s3.put_object(Bucket=bucket, Key=f"{prefix}/dataframe.csv", Body=csv_buf.getvalue())
print("Done")
PYCODE
