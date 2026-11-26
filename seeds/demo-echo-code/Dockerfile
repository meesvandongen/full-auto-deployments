FROM python:3.13-alpine AS test
WORKDIR /app
COPY app/ .
RUN python -m unittest discover -s tests -v

FROM python:3.13-slim AS pact-test
WORKDIR /app
COPY pact/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app/*.py app/
COPY pact/ pact/
CMD ["python", "-m", "unittest", "discover", "-s", "pact", "-v"]

FROM grafana/k6:0.49.0 AS k6-test
WORKDIR /data
COPY tests/load.js .

FROM python:3.13-alpine
WORKDIR /app
COPY app/*.py .
ARG VERSION=local
ENV APP_VERSION=$VERSION
USER 10001
EXPOSE 8080
CMD ["python", "-u", "server.py"]
