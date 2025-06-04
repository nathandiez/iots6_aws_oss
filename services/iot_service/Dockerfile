FROM python:3.9-slim-buster

# Create non-root user
RUN groupadd -r appgroup && useradd -r -g appgroup appuser

WORKDIR /app

COPY requirements.txt .
COPY iot_service.py .

# Install dependencies
RUN apt-get update && \
    apt-get install -y gcc python3-dev libpq-dev && \
    pip install -r requirements.txt && \
    apt-get remove -y gcc python3-dev && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    # Create necessary directories with correct permissions
    mkdir -p /app/logs && \
    chown -R appuser:appgroup /app

# Switch to non-root user
USER appuser

# Make the script executable
RUN chmod +x /app/iot_service.py

CMD ["python", "iot_service.py"]