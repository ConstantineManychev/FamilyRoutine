FROM rust:1-alpine AS builder
RUN apk add --no-cache musl-dev gcc make

WORKDIR /app

COPY Cargo.toml Cargo.lock ./
COPY shared-schema ./shared-schema
COPY backend ./backend

WORKDIR /app/backend
RUN cargo build --release

FROM alpine:latest
RUN apk add --no-cache libgcc
WORKDIR /app
COPY --from=builder /app/target/release/backend ./server
COPY --from=builder /app/backend/migrations ./migrations

CMD ["./server"]