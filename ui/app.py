import streamlit as st
import boto3, json, time

st.title("📦 Python Code Runner")

s3 = boto3.client("s3", region_name=st.secrets["AWS_REGION"])
ecs = boto3.client("ecs", region_name=st.secrets["AWS_REGION"])

zip_file = st.file_uploader("Upload your code ZIP", type="zip")
s3_link = st.text_input("S3 link to input dataframe")
reqs    = st.file_uploader("requirements.txt", type="txt")

if st.button("Run"):
    if not (zip_file and s3_link and reqs):
        st.error("All three inputs are required.")
    else:
        # 1) upload to a temp bucket
        bucket = st.secrets["S3_BUCKET"]
        task_id = str(int(time.time()))
        s3.upload_fileobj(zip_file, bucket, f"{task_id}/code.zip")
        s3.upload_fileobj(reqs, bucket, f"{task_id}/requirements.txt")

        # 2) run task
        resp = ecs.run_task(
            cluster=st.secrets["CLUSTER_NAME"],
            launchType="FARGATE",
            taskDefinition=st.secrets["WORKER_FAMILY"],
            networkConfiguration={
                "awsvpcConfiguration":{
                    "subnets": st.secrets["SUBNETS"].split(","),
                    "assignPublicIp":"ENABLED"
                }
            },
            overrides={"containerOverrides":[
                {"name":"worker","environment":[
                    {"name":"CODE_ZIP_S3","value":f"s3://{bucket}/{task_id}/code.zip"},
                    {"name":"REQS_S3","value":f"s3://{bucket}/{task_id}/requirements.txt"},
                    {"name":"DF_S3","value":s3_link},
                    {"name":"OUT_PREFIX","value":f"{task_id}/out"}
                ]}
            ]]
        )
        arn = resp["tasks"][0]["taskArn"]
        st.write("🚀 Task launched:", arn)

        # 3) wait for stop
        waiter = ecs.get_waiter("tasks_stopped")
        waiter.wait(cluster=st.secrets["CLUSTER_NAME"], tasks=[arn])

        # 4) fetch logs & results
        logs = boto3.client("logs", region_name=st.secrets["AWS_REGION"])
        log_group = "/ecs/worker"
        stream = arn.split("/")[-1]
        events = logs.get_log_events(logGroupName=log_group, logStreamName=stream)["events"]
        for e in events: st.text(e["message"])

        # 5) read result JSON
        out_json = f"s3://{bucket}/{task_id}/out/result.json"
        out_df_s3 = f"s3://{bucket}/{task_id}/out/dataframe.csv"
        st.json(json.loads(s3.get_object(Bucket=bucket, Key=f"{task_id}/out/result.json")["Body"].read()))
        st.write("Output dataframe:", out_df_s3)
