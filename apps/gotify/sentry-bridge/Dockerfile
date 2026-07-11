FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 go build -o /sentry-gotify-bridge .

FROM gcr.io/distroless/static-debian12
COPY --from=build /sentry-gotify-bridge /sentry-gotify-bridge
USER nonroot:nonroot
ENTRYPOINT ["/sentry-gotify-bridge"]
