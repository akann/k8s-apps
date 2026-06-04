FROM ghcr.io/tensorchord/vchord-scratch:pg18-v1.1.1 AS vchord

FROM ghcr.io/cloudnative-pg/postgresql:18
COPY --from=vchord / /

USER postgres
