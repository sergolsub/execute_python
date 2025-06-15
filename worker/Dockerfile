FROM python:3.9-slim

# 1) Install unzip (and clean up apt cache)
RUN apt-get update && \
    apt-get install -y unzip && \
    rm -rf /var/lib/apt/lists/*

# 2) Install AWS CLI and common Python libs
RUN pip install --no-cache-dir awscli pandas boto3

WORKDIR /app

# 3) Copy and make entrypoint executable
COPY entrypoint.sh .
RUN chmod +x entrypoint.sh

ENTRYPOINT ["./entrypoint.sh"]
