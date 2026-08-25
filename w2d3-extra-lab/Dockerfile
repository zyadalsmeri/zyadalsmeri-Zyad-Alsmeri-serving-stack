FROM python:3.11-slim AS builder

WORKDIR /install

COPY app/requirements.txt .

RUN pip install \
    --no-cache-dir \
    --no-compile \
    --prefix=/install/deps \
    -r requirements.txt \
    && find /install/deps -type d -name "__pycache__" -prune -exec rm -rf {} + \
    && find /install/deps -type f \( -name "*.pyc" -o -name "*.pyo" \) -delete \
    && find /install/deps -type d \( -name "tests" -o -name "test" \) -prune -exec rm -rf {} + \
    && rm -rf \
       /install/deps/lib/python3.11/site-packages/uvloop* \
       /install/deps/lib/python3.11/site-packages/httptools* \
       /install/deps/lib/python3.11/site-packages/watchfiles* \
       /install/deps/lib/python3.11/site-packages/websockets* \
       /install/deps/lib/python3.11/site-packages/dotenv* \
       /install/deps/lib/python3.11/site-packages/python_dotenv* \
       /install/deps/lib/python3.11/site-packages/yaml* \
       /install/deps/lib/python3.11/site-packages/PyYAML*


FROM python:3.11-slim AS runtime

WORKDIR /app

COPY --from=builder /install/deps /usr/local

COPY app/main.py app/registry.json ./

ENV PYTHONDONTWRITEBYTECODE=1

EXPOSE 8000

CMD ["uvicorn", "main:app", "--loop", "asyncio", "--http", "h11", "--host", "0.0.0.0", "--port", "8000"]