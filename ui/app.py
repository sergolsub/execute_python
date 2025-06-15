import os
import json
import time
import streamlit as st
import boto3
import botocore.exceptions

# Read required settings from env vars
AWS_REGION    = os.environ["AWS_REGION"]
S3_BUCKET     = os.environ["S3_BUCKET"]
CLUSTER_NAME  = os.environ["CLUSTER_NAME"]
WORKER_FAMILY = os.environ["WORKER_FAMILY"]
SUBNETS       = os.environ["SUBNETS"].split(",")
ECS_SG        = [os.environ["ECS_SG"]]

st.set_page_config(page_title="Python Code Runner")
st.title("📦 Python Code Runner")

# AWS clients
s3  = boto3.client("s3",    region_name=AWS_REGION)
ecs = boto3.client("ecs",   region_name=AWS_REGION)
logs= boto3.client("logs",  region_name=AWS_REGION)

# UI inputs
zip_file = st.file_uploader("Upload your code ZIP", type="zip")
s3_link  = st.text_input("S3 link to input dataframe (s3://…)")
reqs     = st.file_uploader("Upload your requirements.txt", type="txt")

if st.button("Run"):
    if not (zip_file and s3_link and reqs):
        st.error("All three inputs are required.")
    else:
        task_id = str(int(time.time()))

        # 1) Upload the user’s code and requirements
        s3.upload_fileobj(zip_file, S3_BUCKET, f"{task_id}/code.zip")
        s3.upload_fileobj(reqs,    S3_BUCKET, f"{task_id}/requirements.txt")

        # 2) Launch the Fargate task
        resp = ecs.run_task(
            cluster=CLUSTER_NAME,
            launchType="FARGATE",
            taskDefinition=WORKER_FAMILY,
            networkConfiguration={
                "awsvpcConfiguration": {
                    "subnets":        SUBNETS,
                    "assignPublicIp": "ENABLED",
                    "securityGroups": ECS_SG
                }
            },
            overrides={
              "containerOverrides": [{
                "name": "worker",
                "environment": [
                  {"name": "CODE_ZIP_S3", "value": f"s3://{S3_BUCKET}/{task_id}/code.zip"},
                  {"name": "REQS_S3",     "value": f"s3://{S3_BUCKET}/{task_id}/requirements.txt"},
                  {"name": "DF_S3",       "value": s3_link},
                  {"name": "OUT_PREFIX",  "value": f"{task_id}/out"},
                ]
              }]
            }
        )

        tasks = resp.get("tasks", [])
        if not tasks:
            st.error("Failed to start ECS task.")
        else:
            arn = tasks[0]["taskArn"]
            st.write("🚀 Task launched:", arn)

            # 3) Wait for it to finish
            ecs.get_waiter("tasks_stopped").wait(cluster=CLUSTER_NAME, tasks=[arn])

            # 4) Fetch logs robustly
            log_group = "/ecs/worker"
            task_suffix = arn.split("/")[-1]

            # Describe streams by prefix, limit to 1
            streams = logs.describe_log_streams(
                logGroupName=log_group,
                logStreamNamePrefix=task_suffix,
                limit=1
            )["logStreams"]

            if not streams:
                st.warning(f"No log stream found yet for task {task_suffix}. Try again in a moment.")
            else:
                stream_name = streams[0]["logStreamName"]
                events = logs.get_log_events(
                    logGroupName=log_group,
                    logStreamName=stream_name,
                    startFromHead=True
                )["events"]

                st.subheader("Worker logs")
                for e in events:
                    st.text(e["message"])
