FROM rust:1-alpine AS builder

WORKDIR /app
ENV SQLX_OFFLINE=true

COPY Cargo.toml Cargo.lock rustfmt.toml ./
COPY .sqlx ./.sqlx
COPY shared-schema ./shared-schema
COPY backend ./backend

RUN cargo build --release -p backend

FROM alpine:3.22
RUN addgroup -S app && adduser -S -G app -H -s /sbin/nologin app

WORKDIR /app
COPY --from=builder /app/target/release/backend /app/server

USER app
ENV BIND_ADDR=0.0.0.0:3000
EXPOSE 3000

CMD ["/app/server"]
