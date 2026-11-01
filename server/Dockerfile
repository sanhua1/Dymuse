FROM python:3.12-slim
RUN useradd --system --uid 10001 --no-create-home app \
 && mkdir /data && chown app /data
WORKDIR /app
COPY server.py admin.html ./
ENV DYMUSE_STATE=/data DYMUSE_BIND=0.0.0.0 DYMUSE_PORT=8080 PYTHONUNBUFFERED=1
USER app
VOLUME /data
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8080/health',timeout=4)"
CMD ["python", "server.py", "serve"]
