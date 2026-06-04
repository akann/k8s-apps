FROM ghcr.io/cloudnative-pg/postgresql:18

USER root

# Install pgvector (required by vchord)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      postgresql-18-pgvector \
      curl && \
    rm -rf /var/lib/apt/lists/*

# Install VectorChord 1.1.1
RUN curl -L \
  "https://github.com/tensorchord/VectorChord/releases/download/1.1.1/postgresql-18-vchord_1.1.1-1_amd64.deb" \
  -o /tmp/vchord.deb && \
  apt-get install -y /tmp/vchord.deb && \
  rm /tmp/vchord.deb

USER postgres
