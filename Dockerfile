FROM python:3.12-slim-bookworm
EXPOSE 8069
CMD ["python3", "-m", "http.server", "8069"]
