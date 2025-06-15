FROM python:3.9-slim
WORKDIR /app
RUN pip install streamlit boto3
COPY app.py .
ENTRYPOINT ["streamlit", "run", "app.py", "--server.port=8501", "--server.address=0.0.0.0"]
