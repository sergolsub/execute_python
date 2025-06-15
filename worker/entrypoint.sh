#!/usr/bin/env bash
set -euo pipefail

# Expect these env vars:
#   AWS_REGION, CODE_ZIP_S3, REQS_S3, DF_S3, OUT_PREFIX

# 1) Download the user’s code ZIP & requirements.txt
aws --region "${AWS_REGION}" s3 cp "${CODE_ZIP_S3}" code.zip
aws --region "${AWS_REGION}" s3 cp "${REQS_S3}"   requirements.txt

# 2) Unpack the code
unzip code.zip -d code

# If the archive created code/code/, flatten it:
if [ -d code/code ]; then
  mv code/code/* code/
  rm -rf code/code
fi

# 3) Install Python deps
pip install --no-cache-dir -r requirements.txt

# 4) Run the inline Python to load df, exec user code, write outputs
python3 <<'PYCODE'
import os, json, boto3, importlib.util, pandas as pd
from io import StringIO

# Read settings
AWS_REGION   = os.environ["AWS_REGION"]
DF_S3        = os.environ["DF_S3"]
OUT_PREFIX   = os.environ["OUT_PREFIX"]
CODE_ZIP_S3  = os.environ["CODE_ZIP_S3"]

# Parse DF_S3 → bucket/key, load DataFrame
df_path      = DF_S3.replace("s3://", "")
df_bucket, df_key = df_path.split("/", 1)
s3 = boto3.client("s3", region_name=AWS_REGION)
obj = s3.get_object(Bucket=df_bucket, Key=df_key)
df = pd.read_csv(obj["Body"]) if df_key.lower().endswith(".csv") else pd.read_parquet(obj["Body"])

# Dynamically import user’s code
spec = importlib.util.spec_from_file_location("usercode", "code/main.py")
mod  = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# Execute run(df)
result, out_df = mod.run(df)

# Determine output bucket from CODE_ZIP_S3 (same bucket you uploaded code.zip to)
zip_path     = CODE_ZIP_S3.replace("s3://", "")
out_bucket   = zip_path.split("/", 1)[0]
out_prefix   = OUT_PREFIX

# Write result.json
s3.put_object(
    Bucket = out_bucket,
    Key    = f"{out_prefix}/result.json",
    Body   = json.dumps(result).encode("utf-8")
)

# Write dataframe.csv
buf = StringIO()
out_df.to_csv(buf, index=False)
s3.put_object(
    Bucket = out_bucket,
    Key    = f"{out_prefix}/dataframe.csv",
    Body   = buf.getvalue().encode("utf-8")
)

print("Done")
PYCODE
