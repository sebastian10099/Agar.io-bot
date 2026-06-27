# Dockerfile for Flask Dashboard
FROM tiangolo/uwsgi-appimage:latest
COPY . /app
WORKDIR /app
EXPOSE 8080
ENTRYPOINT ["uwsgi", "--socket", ":8080"]