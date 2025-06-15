FROM python:3.9-slim
WORKDIR /app
RUN pip install awscli
COPY entrypoint.sh .
RUN chmod +x entrypoint.sh
ENTRYPOINT ["./entrypoint.sh"]
