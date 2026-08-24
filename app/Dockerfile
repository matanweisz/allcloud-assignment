FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
# NOTE: app.py listens on 8080 - check this matches what's below
EXPOSE 8080
CMD ["python", "app.py"]
