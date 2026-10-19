FROM python:3.10-slim

# Install ping and curl so our runtime exploit triggers eBPF CWS rules
RUN apt-get update && apt-get install -y iputils-ping curl awscli && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# Datadog Source Code Integration tags (passed during CI build)
ARG DD_GIT_REPOSITORY_URL
ARG DD_GIT_COMMIT_SHA
ENV DD_GIT_REPOSITORY_URL=${DD_GIT_REPOSITORY_URL}
ENV DD_GIT_COMMIT_SHA=${DD_GIT_COMMIT_SHA}

# Run with ddtrace-run to auto-instrument APM, ASM, and IAST
CMD ["ddtrace-run", "python", "app.py"]
