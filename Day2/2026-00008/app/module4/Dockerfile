FROM public.ecr.aws/docker/library/python:3.12-slim
WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt
COPY worker.py /app/worker.py
CMD ["python", "worker.py"]
