FROM python:3.12-slim

WORKDIR /app
COPY server.py /app/server.py
COPY static /app/static

ENV RESULTS_DIR=/data
ENV WPT_DIR=/wpt
ENV PORT=8188
EXPOSE 8188
CMD ["python3", "/app/server.py"]
